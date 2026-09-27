#!/usr/bin/env python3
"""Extract ASC API usage context from the 2026-08-11 Codex session."""
import re

f = r"C:\Users\17941\.codex\sessions\2026\08\11\rollout-2026-08-11T16-06-13-019fefdb-982d-7121-8e4f-fe5ca8923490.jsonl"
for line in open(f, encoding="utf-8", errors="replace"):
    if "appstoreconnect" in line or "key_id" in line:
        # find windows around each match
        for m in re.finditer(r"appstoreconnect|key_id|issuer", line):
            s = max(0, m.start() - 300)
            e = min(len(line), m.end() + 300)
            window = line[s:e]
            if "key_id" in window or "issuer" in window:
                print(window)
                print("=" * 80)
