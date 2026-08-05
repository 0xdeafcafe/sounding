#!/usr/bin/env python3
"""Minimal parser for Serato's 'database V2' file.

Format (reverse-engineered, matches public documentation of the format used
by Mixxx / serato-tags projects): a flat sequence of TLV chunks:
    4-byte ASCII tag, 4-byte big-endian uint32 length, <length> bytes payload.

Container tags (e.g. 'otrk' = one track record) have a payload that is
itself a sequence of the same TLV chunks. Leaf tags are typed by convention
of their first letter: 't' = UTF-16BE text, 'p' = UTF-16BE path text,
'b' = 1-byte bool, 's' = 2-byte signed int, 'u' = 4-byte unsigned int.
"""
import struct
import sys

TEXT_PREFIXES = ("t", "p")


def parse_chunks(data, offset=0, end=None):
    if end is None:
        end = len(data)
    chunks = []
    while offset < end:
        if offset + 8 > end:
            break
        tag = data[offset:offset + 4].decode("ascii", errors="replace")
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        payload = data[offset + 8:offset + 8 + length]
        chunks.append((tag, payload))
        offset += 8 + length
    return chunks


def decode_leaf(tag, payload):
    if tag[0] in TEXT_PREFIXES:
        try:
            return payload.decode("utf-16-be")
        except Exception:
            return payload
    if len(payload) == 1:
        return payload[0]
    if len(payload) == 2:
        return struct.unpack(">H", payload)[0]
    if len(payload) == 4:
        return struct.unpack(">I", payload)[0]
    return payload


def parse_track(payload):
    fields = {}
    for tag, sub in parse_chunks(payload):
        fields[tag] = decode_leaf(tag, sub)
    return fields


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/Users/afr/Music/_Serato_/database V2"
    data = open(path, "rb").read()
    top = parse_chunks(data)
    print(f"# total top-level chunks: {len(top)}", file=sys.stderr)
    tags_seen = {}
    tracks = []
    for tag, payload in top:
        tags_seen[tag] = tags_seen.get(tag, 0) + 1
        if tag == "otrk":
            tracks.append(parse_track(payload))
    print(f"# top-level tag histogram: {tags_seen}", file=sys.stderr)
    print(f"# track records (otrk): {len(tracks)}", file=sys.stderr)
    # Dump distinct field-tag vocabulary seen across all tracks, for sanity.
    field_tags = {}
    for t in tracks:
        for k in t:
            field_tags[k] = field_tags.get(k, 0) + 1
    print(f"# field tags across tracks: {sorted(field_tags.items())}", file=sys.stderr)

    import json
    out = []
    for t in tracks:
        out.append({
            "pfil": t.get("pfil"),
            "tsng": t.get("tsng"),
            "tart": t.get("tart"),
            "tbpm": t.get("tbpm"),
            "tkey": t.get("tkey"),
            "tlen": t.get("tlen"),
            "ttyp": t.get("ttyp"),
        })
    json.dump(out, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
