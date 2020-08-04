# cython: language_level=3

from skbio.alignment import StripedSmithWaterman
from dysgu.map_set_utils cimport is_overlapping
from dysgu.coverage import merge_intervals

import edlib
import click


def echo(*args):
    click.echo(args, err=True)


def get_clipped_seq(cont, position, cont_ref_start, cont_ref_end):
    if cont:
        start_i = 1
        while cont[start_i].islower():
            start_i += 1
            if start_i == len(cont):
                break
        end_i = len(cont) - 1
        while cont[end_i].islower():
            end_i -= 1
            if end_i < 0:
                break

        if abs(cont_ref_start - position) < abs(cont_ref_end - position):
            left_clip = ""
            # if cont[0].islower():
            #     start_i = 1
            if start_i > 8:
                left_clip = cont[:start_i - 1]
                return left_clip, 0, len(cont) - end_i
        else:
            right_clip = ""
            # if cont[-1].islower():

            if len(cont) - end_i > 8:
                right_clip = cont[end_i + 1:]#, 1
                return right_clip, 1, start_i


def filter_bad_alignment(align, event, idx, clip_side, begin, end, break_position, clip_seq):
    pos = event["pos" + idx]
    score = align['optimal_alignment_score']
    span = align["query_end"] - align["query_begin"] + 1
    seq1 = align['aligned_query_sequence']
    seq2 = align['aligned_target_sequence']

    if not seq1 or not seq2:
        return -1
    if align.target_begin > 8 and len(align.target_sequence) - align.target_end_optimal > 8:
        return -1

    distance_to_break = min(abs(begin - break_position), abs(end - break_position))
    large_gap_penalty = 24
    gapped_score = score
    if distance_to_break > 200:
        gapped_score = score - large_gap_penalty

    if gapped_score > 12:
        if is_overlapping(begin - 1, end + 1, pos, pos + 1):
            return 1
        elif gapped_score > 20:
            expected = span * 2  # 2 x match score
            # if gaps at both ends of alignment increase stringency
            if align.target_begin >= 2 and align.target_end_optimal < len(align.target_sequence) - 2:
                expected = span * 4
            # echo("HERE", expected, span, score/expected, align.target_begin, len(align.target_sequence) - align.target_end_optimal)
            if span > 12 and float(score) / expected > 0.7:
                return 1
    return -1

def merge_align_regions(locations):
    # Merge any similar alignment regions found by edlib, used to get the bounds of the alignment region
    if len(locations) <= 1:
        return locations
    merge_dist = 10
    new_l = []
    for s, e in locations:
        if len(new_l) == 0:
            new_l.append([s, e])
        last = new_l[-1]

        if abs(s - last[0]) < merge_dist and abs(e - last[1]) < merge_dist:
            new_l[-1][1] = e
        else:
            return None
    return new_l


def remap_soft_clips(events, ref_genome, min_sv_len):

    new_events = []
    try_remap_events = []
    ref_locs = []

    for count, e in enumerate(events):
        e["remapped"] = 0
        e["remap_score"] = 0
        if 'svlen_precise' not in e:
            e['svlen_precise'] = 1

        if e["chrA"] != e["chrB"]:
            new_events.append(e)
            continue

        try_remap = False
        if (e["contig"] or e["contig2"]) and (e["svlen"] < 1000):
            if not e['svlen_precise']:
                try_remap = True

        if not try_remap:
            e["modified"] = 0
            new_events.append(e)
            continue

        else:
            if e["posA"] <= e["posB"]:
                ref_locs.append((e["chrA"], e["posA"], e["posB"], count))
            else:
                ref_locs.append((e["chrA"], e["posB"], e["posA"], count))

    for chrom, gstart, gend, grp_idxs in merge_intervals(ref_locs, pad=1500, add_indexes=True):
        if gstart < 0:
            gstart = 0

        ref_seq_big = None

        for index in grp_idxs:
            e = events[index]

            added = 0
            passed = False
            high_quality_clip = False
            # echo(e["chrA"], e["posA"], e["posB"])
            for cont, idx in (("contig", "A"), ("contig2", "B")):
                if cont in e and e[cont]:

                    break_position = e["pos" + idx]
                    clip_res = get_clipped_seq(e[cont], break_position, e[cont + "_ref_start"], e[cont + "_ref_end"])
                    if not clip_res:
                        continue
                    clip_seq, clip_side, length_other_clip = clip_res

                    if length_other_clip > 3 and e['ref_bases'] < 50:
                        continue

                    if clip_side == 0:
                        w = e[cont + "_left_weight"]
                        if not w > 10:  # todo set as a parameter option
                            continue
                        elif w > 400:
                            high_quality_clip = True
                    else:
                        w = e[cont + "_right_weight"]
                        if not w > 10:
                            continue
                        elif w > 400:
                            high_quality_clip = True

                    ref_start = break_position - 500
                    ref_end = break_position + 500

                    start_idx = ref_start - gstart
                    start_idx = 0 if start_idx < 0 else start_idx
                    end_idx = ref_end - gstart
                    if ref_seq_big is None:
                        try:
                            ref_seq_big = ref_genome.fetch(chrom, gstart, gend).upper()
                        except ValueError:
                            continue

                    ref_seq_clipped = ref_seq_big[start_idx:end_idx]

                    ref_seq_start = gstart + start_idx
                    ref_seq_end = gstart + end_idx

                    if not ref_seq_clipped or ref_seq_clipped[0] in "nN" or ref_seq_clipped[-1] in "nN":
                        continue

                    # Large alignment region
                    el = edlib.align(clip_seq.upper(), ref_seq_clipped, mode="HW", task="path")
                    locs = merge_align_regions(el['locations'])
                    if not locs:
                        continue

                    l_start, l_end = locs[0]

                    ref_start2 = ref_seq_start + l_start
                    ref_end2 = ref_seq_start + l_end
                    ref_seq2 = ref_seq_clipped[l_start:l_end+1]

                    aln = StripedSmithWaterman(ref_seq2, match_score=2, mismatch_score=-8, gap_open_penalty=12, gap_extend_penalty=1)
                    a = aln(clip_seq)

                    aligned_seq = a.aligned_target_sequence
                    score = a.optimal_alignment_score

                    aln_q_end = a.query_end
                    aln_q_begin = a.query_begin
                    aln_t_begin = a.target_begin
                    target_end_optimal = a.target_end_optimal

                    q_begin = ref_start2 + aln_q_begin
                    q_end = break_point = ref_start2 + aln_q_end

                    f = filter_bad_alignment(a, e, idx, clip_side, q_begin, q_end, break_position, clip_seq)

                    if f != -1:

                        pos = e["pos" + idx]
                        target_gap = None
                        ref_gap = None
                        if clip_side == 0:
                            if q_end + 1 >= pos:
                                kind = "INS"
                                break_point = pos
                                break_point2 = pos
                                overlap = q_end - pos
                                svlen = len(clip_seq) - target_end_optimal + overlap
                            else:
                                ref_gap = pos - q_end
                                target_gap = len(clip_seq) - target_end_optimal

                                if target_gap > ref_gap:
                                    kind = "INS"
                                    break_point = pos
                                    break_point2 = pos
                                    svlen = target_gap

                                else:
                                    kind = "DEL"
                                    break_point = pos
                                    break_point2 = q_end
                                    svlen = ref_gap

                            # discard alignments with large unmapped overhang
                            if aln_t_begin > svlen:
                                passed = False
                                continue
                        else:

                            if q_begin - 1 <= pos:
                                kind = "INS"
                                break_point = pos
                                break_point2 = pos
                                if q_end > pos:
                                    svlen = pos - q_begin + aln_t_begin
                                else:
                                    svlen = max(q_end, pos) -  min(q_begin, pos)

                            else:
                                ref_gap = q_begin - pos
                                target_gap = aln_t_begin
                                if target_gap > ref_gap:
                                    kind = "INS"
                                    break_point = pos
                                    break_point2 = pos
                                    svlen = target_gap
                                else:
                                    kind = "DEL"
                                    break_point = pos
                                    break_point2 = q_begin
                                    svlen = break_point2 - break_point

                            if len(clip_seq) - target_end_optimal > svlen:
                                passed = False
                                continue

                        if svlen < min_sv_len:
                            continue

                        if kind == "DEL":
                            span = a.query_end - a.query_begin + 1
                            if span < len(clip_seq) * 0.4 and span < 50:
                                continue

                        # echo("BREAKPOINT", break_point)
                        # echo("aligb", a)
                        # echo(e)
                        # echo("--", kind, "pos" + idx, break_point, break_point2)

                        if abs(svlen - e['svlen']) > 20:
                            e["remapped"] = 1
                            e["remap_score"] = score
                            # if e['svtype'] != kind:
                            #     e["switched"] = 1

                            e['svtype'] = kind
                            e['svlen'] = svlen
                            e['pos' + idx] = break_point
                            if idx == "A":
                                other = "B"
                            else:
                                other = "A"
                            e['pos' + other] = break_point2
                            e['cipos95A'] = 0
                            e['cipos95B'] = 0
                            new_events.append(e)
                            added = 1
                            break  # dont analyse contig2

                    else:
                        passed = False

                if added:
                    break

            if not added and high_quality_clip:
                new_events.append(e)

    return new_events
