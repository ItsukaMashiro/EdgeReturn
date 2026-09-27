#!/usr/bin/env python3
"""Search all Codex sessions for ASC JWT usage (aud=appstoreconnect-v1, ES256, kid)."""
import glob
import re

files = glob.glob(r"C:\Users\17941\.codex\sessions\**\rollout-*.jsonl", recursive=True)
pats = [
    r"appstoreconnect-v1",
    r"ES256",
    r'"kid"\s*:\s*"[A-Z0-9]{4,20}"',
    r"kid[=:]\s*[A-Z0-9]{4,20}",
    r"api\.appstoreconnect",
    r"asc[_-]?api[_-]?key",
]
hits = {}
for f in files:
    try:
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace")):
            for p in pats:
                for m in re.finditer(p, line):
                    key = m.group(0)
                    if key not in hits:
                        hits[key] = (f, i)
    except Exception:
        pass
for k, (f, i) in sorted(hits.items()):
    print(f"{k!r:45} {f.split('sessions')[-1][:40]} line {i}")
print("total:", len(hits))
