#cython: language_level=3

from __future__ import absolute_import
import pysam
import time
import datetime
import numpy as np
cimport numpy as np
from collections import deque
import os

from libc.stdint cimport uint32_t, int16_t

from dysgu import io_funcs
from dysgu cimport map_set_utils
from dysgu.map_set_utils cimport unordered_set
from dysgu.coverage import get_insert_params

import logging


class Py_CoverageTrack(object):

    def __init__(self, outpath, infile):
        self.current_chrom = -1
        self.outpath = outpath
        self.cov_array = np.array([], dtype="int32")
        self.infile = infile

    def add(self, a):

        if a.flag & 1284 or a.mapq == 0 or a.cigartuples is None:  # not primary, duplicate or unmapped, low mapq
            return

        if self.current_chrom != a.rname:

            self.write_track()
            self.set_cov_array(a.rname)
            self.current_chrom = a.rname

        arr = self.cov_array

        if int(a.pos  / 10) > len(arr) - 1:
            return

        index_start = a.pos
        index_bin = int(index_start / 10)
        for opp, length in a.cigartuples:
            if index_bin > len(arr) - 1:
                break
            if opp == 2:
                index_start += length
                index_bin = int(index_start / 10)
            elif opp == 0 or opp == 7 or opp == 8:
                # if -32000 < arr[index_bin] < 32000:
                arr[index_bin] += 1
                index_start += length
                index_bin = int(index_start / 10)
                if index_bin < len(arr):
                    arr[index_bin] -= 1

    def set_cov_array(self, int rname):
        chrom_length = self.infile.get_reference_length(self.infile.get_reference_name(rname))
        self.cov_array = np.resize(self.cov_array, int(chrom_length / 10) + 1)
        self.cov_array.fill(0)

    def write_track(self):
        cdef np.ndarray[int16_t, ndim=1] ca = self.cov_array
        cdef int current_cov = 0
        cdef int16_t v
        cdef int i
        if self.current_chrom != -1:
            out_path = "{}/{}.dysgu_chrom.bin".format(self.outpath, self.infile.get_reference_name(self.current_chrom))
            for i in range(len(ca)):
                v = ca[i]
                current_cov += v
                if current_cov < 32000:
                    ca[i] = current_cov
                elif current_cov < 0:
                    ca[i] = 0  # sanity check
                elif current_cov >= 32000:
                    ca[i] = 32000
            ca.tofile(out_path)


def iter_bam(bam, search, show=True):
    if not search:
        for aln in bam.fetch(until_eof=True):  # Also get unmapped reads
            yield aln
    else:
        if show:
            logging.info("Limiting search to {}".format(search))
        with open(search, "r") as bed:
            for line in bed:
                if line[0] == "#":
                    continue
                chrom, start, end = line.split("\t")[:3]
                for aln in bam.fetch(reference=chrom, start=int(start), end=int(end)):  # Also get unmapped reads
                    yield aln


def config(args):

    kind = args["bam"].split(".")[-1]
    opts = {"bam": "rb", "cram": "rc", "sam": "r"}
    if kind not in opts:
        raise ValueError("Input file format not recognized, use .bam,.sam or .cram extension")
    try:
        bam = pysam.AlignmentFile(args["bam"], opts[kind], threads=args["procs"])
    except:
        raise RuntimeError("Problem opening bam/sam/cram, check file has .bam/.sam/.cram in file name, and file has a header")

    bam_i = iter_bam(bam, args["search"] if "search" in args else None)

    clip_length = args["clip_length"]
    send_output = None
    v = ""
    if "reads" in args and args["reads"] != "None":
        if args["reads"] == "stdout":
            v = "-"
        else:
            v = args["reads"]
        send_output = pysam.AlignmentFile(v, "wb", template=bam)
    out_name = "-" if (args["output"] == "-" or args["output"] == "stdout") else args["output"]
    reads_out = pysam.AlignmentFile(out_name, "wbu", template=bam)

    return bam, bam_i, clip_length, send_output, reads_out


cdef tuple get_reads(bam, bam_i, exc_tree, int clip_length, send_output, outbam, min_sv_size, pe, temp_dir):

    cdef int flag
    cdef long qname
    cdef list cigartuples

    # Borrowed from lumpy
    cdef int required = 97
    restricted = 3484
    cdef int flag_mask = required | restricted

    scope = deque([])
    cdef unordered_set[long] read_names

    insert_size = []
    read_length = []

    cdef int max_scope = 100000
    if not pe:
        max_scope = 100
    cdef int count = 0
    cdef int nn = 0
    cdef bint paired_end = 0

    cov_track = Py_CoverageTrack(temp_dir, bam)

    for nn, r in enumerate(bam_i):

        if send_output:
            send_output.write(r)

        while len(scope) > max_scope:
            qname, query = scope.popleft()
            if read_names.find(qname) != read_names.end():
                outbam.write(query)
                count += 1

        if exc_tree:  # Skip exclude regions
            if io_funcs.intersecter_int_chrom(exc_tree, r.rname, r.pos, r.pos + 1):
                continue

        flag = r.flag
        if flag & 1028 or r.cigartuples is None:
            continue  # Read is duplicate or unmapped

        if flag & 1 and len(insert_size) < 100000:  # read_paired
            paired_end = 1
            if r.seq is not None:
                if r.rname == r.rnext and r.flag & flag_mask == required and r.tlen >= 0:
                    read_length.append(r.infer_read_length())
                    insert_size.append(r.tlen)

        qname = r.qname.__hash__()
        scope.append((qname, r))

        cov_track.add(r)

        if read_names.find(qname) == read_names.end():
            if clip_length > 0 and map_set_utils.cigar_clip(r, clip_length):
                read_names.insert(qname)
            elif (~flag & 2 and flag & 1) or flag & 2048:  # Save if read is discordant or supplementary
                read_names.insert(qname)
            elif r.has_tag("SA"):
                read_names.insert(qname)
            elif any((j == 1 or j == 2) and k >= min_sv_size for j, k in r.cigartuples):
                read_names.insert(qname)

    while len(scope) > 0:
        qname, query = scope.popleft()
        if read_names.find(qname) != read_names.end():
            outbam.write(query)
            count += 1

    outbam.close()
    if send_output:
        send_output.close()

    logging.info("Total input reads in bam {}".format(nn + 1))
    insert_median, insert_stdev, approx_read_length = 0, 0, 0

    if paired_end:
        if len(read_length) == 0:
            raise ValueError("No paired end reads")
        approx_read_length = int(np.mean(read_length))
        if len(insert_size) == 0:
            insert_median, insert_stdev = 300, 150
            logging.warning("Could not infer insert size, no 'normal' pairings found. Using arbitrary values")
        else:
            insert_median, insert_stdev = get_insert_params(insert_size)
            insert_median, insert_stdev = np.round(insert_median, 2), np.round(insert_stdev, 2)
        logging.info(f"Inferred read length {approx_read_length}, insert median {insert_median}, insert stdev {insert_stdev}")

    return count, insert_median, insert_stdev, approx_read_length


cdef extern from "find_reads.h":
    cdef int search_hts_alignments(char* infile, char* outfile, uint32_t min_within_size, int clip_length, int mapq_thresh,
                                    int threads, int paired_end, char* temp_f)

def process(args):

    t0 = time.time()
    temp_dir = args["working_directory"]
    assert os.path.exists(temp_dir)
    exc_tree = None
    if "exclude" in args and args["exclude"]:
        logging.info("Excluding {} from search".format(args["exclude"]))
        exc_tree = io_funcs.overlap_regions(args["exclude"])

    bname = os.path.splitext(os.path.basename(args["bam"]))[0]
    if bname == "-":
        bname = os.path.basename(temp_dir)

    out_name = "{}/{}.{}.bam".format(temp_dir, bname, args["pfix"])
    pe = int(args["pl"] == "pe")

    cdef bytes infile_string = args["bam"].encode("ascii")
    cdef bytes outfile_string = out_name.encode("ascii")
    cdef bytes temp_f = temp_dir.encode("ascii")

    if exc_tree is None:
        count = search_hts_alignments(infile_string, outfile_string, args["min_size"], args["clip_length"], args["mq"], args["procs"], pe, temp_f)

    else:
        bam, bam_i, clip_length, send_output, outbam = config(args)
        count, insert_median, insert_stdev, read_length = get_reads(bam, bam_i, exc_tree, clip_length, send_output, outbam,
                                                                args["min_size"], pe, temp_dir)
    if count < 0:
        logging.critical("Error reading from input file, exit code {}".format(count))
        quit()
    elif count == 0:
        logging.critical("No reads found")
        quit()
    logging.info("dysgu fetch {} written to {}, n={}, time={} h:m:s".format(args["bam"], out_name,
                                                            count,
                                                            str(datetime.timedelta(seconds=int(time.time() - t0)))))
