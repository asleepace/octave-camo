#!/usr/bin/env python3
"""Every relative link in the repo's Markdown points at a file that exists.

    python3 scripts/check-links.py        (from the repo root; CI runs it)
"""
import os
import re
import subprocess
import sys

link = re.compile(r"\]\(([^)\s]+)\)")
broken = []
for f in subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.split():
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        for target in link.findall(line):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if path and not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(f), path))):
                broken.append(f"{f}:{n}: {target}")
print("\n".join(broken) or "all relative links resolve")
sys.exit(1 if broken else 0)
