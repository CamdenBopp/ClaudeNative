#!/usr/bin/env python3
"""Summarize ChatMarkdownKit signpost intervals/events from an xctrace XML export."""
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

OUR_SUBSYSTEM = "net.bopp.ChatMarkdownKit"

def main(path):
    tree = ET.parse(path)
    root = tree.getroot()

    # xctrace compresses repeated elements: first occurrence carries id=...,
    # later ones are <tag ref=.../>. Resolve by id.
    by_id = {}

    def resolve(el):
        ref = el.get("ref")
        if ref is not None:
            return by_id.get(ref, el)
        el_id = el.get("id")
        if el_id is not None:
            by_id[el_id] = el
        return el

    def text_of(el):
        el = resolve(el)
        return "".join(el.itertext()).strip()

    # Column order comes from the schema.
    schema = root.find(".//schema")
    mnemonics = [col.find("mnemonic").text for col in schema.findall("col")]

    intervals = defaultdict(list)   # name -> [duration_ns]
    events = defaultdict(int)       # name -> count
    open_begins = {}                # (name, thread) -> start_ns
    unmatched_ends = 0
    first_ts = None
    last_ts = None

    for row in root.iter("row"):
        cells = list(row)
        if len(cells) != len(mnemonics):
            continue
        # Resolve EVERY cell first: id-carrying elements appear in whichever
        # row uses them first — including rows from other subsystems that we
        # filter out. Skipping before resolving would orphan later refs.
        data = {m: resolve(c) for m, c in zip(mnemonics, cells)}
        subsystem = text_of(data["subsystem"]) if "subsystem" in data else ""
        if OUR_SUBSYSTEM not in subsystem:
            continue
        name = text_of(data["name"])
        event_type = text_of(data["event-type"]).lower()
        ts_el = data["time"]
        ts = int(ts_el.text or "".join(ts_el.itertext()).strip())
        thread = data["thread"].get("fmt", "") if "thread" in data else ""
        first_ts = ts if first_ts is None else min(first_ts, ts)
        last_ts = ts if last_ts is None else max(last_ts, ts)

        key = (name, thread)
        if "begin" in event_type:
            open_begins[key] = ts
        elif "end" in event_type:
            start = open_begins.pop(key, None)
            if start is None:
                unmatched_ends += 1
            else:
                intervals[name].append(ts - start)
        else:
            events[name] += 1

    def pct(values, p):
        values = sorted(values)
        if not values:
            return 0
        idx = min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))
        return values[idx]

    span_s = ((last_ts or 0) - (first_ts or 0)) / 1e9
    print(f"trace span with our signposts: {span_s:.1f}s")
    print(f"unmatched ends: {unmatched_ends}, dangling begins: {len(open_begins)}")
    print()
    print(f"{'interval':<28}{'count':>7}{'p50 ms':>10}{'p95 ms':>10}{'max ms':>10}{'total ms':>10}")
    for name in sorted(intervals, key=lambda n: -sum(intervals[n])):
        vals = intervals[name]
        print(f"{name:<28}{len(vals):>7}"
              f"{pct(vals, 50)/1e6:>10.2f}{pct(vals, 95)/1e6:>10.2f}"
              f"{max(vals)/1e6:>10.2f}{sum(vals)/1e6:>10.1f}")
    print()
    print(f"{'event':<28}{'count':>7}")
    for name in sorted(events, key=lambda n: -events[n]):
        print(f"{name:<28}{events[name]:>7}")

if __name__ == "__main__":
    main(sys.argv[1])
