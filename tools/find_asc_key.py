#!/usr/bin/env python3
"""Find where the ASC API key was created: search sessions for ASC key id / issuer / JWT."""
import glob
import re

files = glob.glob(r"C:\Users\17941\.codex\sessions\**\rollout-*.jsonl", recursive=True)
pats = [
    r"App Store Connect",
    r"appstoreconnect",
    r"api[_ ]?key",
    r"issuer",
    r"teamId|team_id|W7N8KKFFF2",
    r"BEGIN PRIVATE KEY",
    r"asc.*key|key.*asc",
]
for f in files:
    try:
        content = open(f, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    hits = []
    for p in pats:
        for m in re.finditer(p, content, re.IGNORECASE):
            s = max(0, m.start() - 150)
            e = min(len(content), m.end() + 250)
            win = content[s:e].replace("\n", " ").replace("\r", " ")
            hits.append((m.group(0), win))
    if any("appstoreconnect" in h[0].lower() or "app store connect" in h[0].lower() for h in hits):
        print("=== HIT:", f.split("sessions")[-1])
        for h in hits[:6]:
            print("   ", h[1][:380])
        print()
