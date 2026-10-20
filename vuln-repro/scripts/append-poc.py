#!/usr/bin/env python3
"""Append a full PoC source file to a Markdown report as a fenced appendix.

Usage:
  append-poc.py --md report-zh.md --poc poc.ps1 \
                --heading "附录 A：PoC 完整代码（poc.ps1）" --lang powershell

The report must not already contain the heading; use --force to append anyway.
"""
import argparse
import re
import sys
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True)
    ap.add_argument("--poc", required=True)
    ap.add_argument("--heading", required=True)
    ap.add_argument("--lang", default="")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    md = Path(args.md)
    poc = Path(args.poc)
    if not md.exists():
        sys.exit(f"missing markdown: {md}")
    if not poc.exists():
        sys.exit(f"missing poc: {poc}")

    text = md.read_text(encoding="utf-8")
    # Match on the appendix label (e.g. "附录 A") so a report skeleton that
    # already has "## 附录 A：PoC 完整代码" blocks a --heading variant like
    # "附录 A：PoC 完整代码（poc.ps1）" — re-runs cannot create two appendix A.
    m = re.match(r"^(附录 [A-Z])\s*[：:]", args.heading)
    key = m.group(1) if m else args.heading
    if re.search(rf"^## {re.escape(key)}\b", text, re.M) and not args.force:
        sys.exit(f"appendix already present: '{key}…' (use --force to append)")

    code = poc.read_text(encoding="utf-8").rstrip("\n")
    fence = "```"
    block = f"\n## {args.heading}\n\n{fence}{args.lang}\n{code}\n{fence}\n"
    md.write_text(text.rstrip("\n") + "\n" + block, encoding="utf-8")
    print(f"appended {poc} to {md} as '{args.heading}'")


if __name__ == "__main__":
    main()
