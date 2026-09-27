#!/usr/bin/env python3
"""Search Codex sessions for ASC API identifiers (key_id, issuer, team)."""
import re

files = [
    r"C:\Users\17941\.codex\sessions\2026\03\22\rollout-2026-03-22T11-21-05-019d138f-81ea-7e61-89c8-8bec4dbed701.jsonl",
    r"C:\Users\17941\.codex\sessions\2026\04\07\rollout-2026-04-07T12-41-47-019d663f-2351-7092-b473-b42a6cc5eda4.jsonl",
    r"C:\Users\17941\.codex\sessions\2026\08\11\rollout-2026-08-11T16-06-13-019fefdb-982d-7121-8e4f-fe5ca8923490.jsonl",
]
pats = [
    r"appstoreconnect[^\s\"\\]{0,50}",
    r"key_id[^\s\"\\]{0,50}",
    r'"kid[^\s\"\\]{0,50}',
    r"issuer_id[^\s\"\\]{0,50}",
    r"issuerId[^\s\"\\]{0,50}",
    r"W7N8KKFFF2",
]
seen = set()
for f in files:
    try:
        for line in open(f, encoding="utf-8", errors="replace"):
            for p in pats:
                for m in re.finditer(p, line):
                    v = m.group(0)
                    if v not in seen:
                        seen.add(v)
                        print(f.split("sessions")[-1][:25], "|", v[:80])
    except Exception as e:
        print("ERR", f, e)
print("done", len(seen))
