#!/usr/bin/env python3
"""Build an evidence manifest (JSON) from a directory tree.

Usage:
  build-manifest.py --dir evidence --out evidence/manifest.json [--verified]

Each regular file becomes:
  {id, type, description, path, sha256, bytes, timestamp, source, verified}

`verified` defaults to false; pass --verified only after the evidence has been
reviewed and is safe for report/video consumption.
"""
import argparse
import datetime as dt
import hashlib
import json
import mimetypes
import os
from pathlib import Path


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--verified", action="store_true")
    args = ap.parse_args()

    root = Path(args.dir).resolve()
    out = Path(args.out).resolve()
    if not root.is_dir():
        raise SystemExit(f"not a directory: {root}")

    entries = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.resolve() == out:
            continue
        rel = path.relative_to(root).as_posix()
        # skip editor/OS junk and bytecode caches
        if any(part.startswith(".") or part == "__pycache__" for part in Path(rel).parts):
            continue
        digest = sha256(path)
        # id is salted with the relative path so identical content at different
        # paths (e.g. empty placeholder logs) gets distinct ids; the sha256
        # field stays the pure content hash for integrity checking.
        id_hash = hashlib.sha256(rel.encode("utf-8") + digest.encode()).hexdigest()
        st = path.stat()
        mime, _ = mimetypes.guess_type(str(path))
        entries.append({
            "id": f"ev_{id_hash[:16]}",
            "type": mime or path.suffix.lstrip(".") or "file",
            "description": rel,
            "path": rel,
            "sha256": digest,
            "bytes": st.st_size,
            "timestamp": dt.datetime.fromtimestamp(
                st.st_mtime, tz=dt.timezone.utc
            ).isoformat(),
            "source": "local",
            "verified": bool(args.verified),
        })

    payload = {
        "root": str(root),
        "generated_at": dt.datetime.now(tz=dt.timezone.utc).isoformat(),
        "verified": bool(args.verified),
        "count": len(entries),
        "entries": entries,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out} ({len(entries)} entries)")


if __name__ == "__main__":
    main()
