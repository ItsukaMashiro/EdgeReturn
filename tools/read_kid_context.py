#!/usr/bin/env python3
import glob

targets = [
    (r"C:\Users\17941\.codex\sessions\2026\09\10\rollout-2026-09-10T22-34-55-*.jsonl", 39, "kid=37020"),
    (r"C:\Users\17941\.codex\sessions\2026\08\10\rollout-2026-08-10T21-55-36-*.jsonl", 34, "kid=2061461"),
]
for pat, lineno, needle in targets:
    files = glob.glob(pat)
    for f in files:
        lines = open(f, encoding="utf-8", errors="replace").readlines()
        if lineno < len(lines):
            line = lines[lineno]
            idx = line.find(needle)
            if idx >= 0:
                s = max(0, idx - 500)
                e = min(len(line), idx + 500)
                print(f"FILE: {f.split('sessions')[-1]}")
                print(line[s:e])
                print("=" * 100)
