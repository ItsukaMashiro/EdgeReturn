#!/usr/bin/env python3
"""Find the provisioner session: search sessions for keyring + provisioner + ASC key creation."""
import glob
import re

files = glob.glob(r"C:\Users\17941\.codex\sessions\**\rollout-*.jsonl", recursive=True)
print("total sessions:", len(files))
for f in files:
    try:
        content = open(f, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    if "codex-wda-provisioner" in content or ("keyring" in content and "provision" in content.lower()):
        print("HIT:", f)
        # show context around 'codex-wda-provisioner' or 'keyring'
        for m in re.finditer(r"codex-wda-provisioner|keyring", content):
            s = max(0, m.start() - 200)
            e = min(len(content), m.end() + 300)
            print("  ...", content[s:e].replace("\n", " ")[:500])
            print("-" * 60)
