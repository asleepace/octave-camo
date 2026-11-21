"""`lab fetch-corpus`: download the public corpus into $LAB_DATA and check it.

Pathak, P. (2026). Aeroplane data full analysis and raw files. Zenodo, record 23424278. CC BY 4.0.

Reads the record's file list from Zenodo's API, downloads each file into
$LAB_DATA/external/zenodo-23424278/raw (resuming a partial download), checks its md5 against the
record, and unzips each zip into extracted/. Files already there with the right md5 are skipped.
Never run in CI: the corpus stays in $LAB_DATA (CLAUDE.md).
"""
from __future__ import annotations

import hashlib
import json
import urllib.request
import zipfile
from pathlib import Path

RECORD = 23424278
API = f"https://zenodo.org/api/records/{RECORD}"
CHUNK = 1 << 20


def md5(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, dst: Path, want_md5: str, log=print) -> bool:
    """dst with the right md5, resuming from dst.part if a download was cut off. True if it fetched
    anything. A wrong md5 removes the partial file and stops, so a rerun starts clean."""
    if dst.exists() and md5(dst) == want_md5:
        return False
    part = dst.with_name(dst.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    with urllib.request.urlopen(req, timeout=60) as r:
        if have and r.status != 206:              # the server ignored the range: start over
            have = 0
        with part.open("ab" if have else "wb") as f:
            for block in iter(lambda: r.read(CHUNK), b""):
                f.write(block)
    got = md5(part)
    if got != want_md5:
        part.unlink()
        raise SystemExit(f"{dst.name}: md5 {got}, the record says {want_md5}; removed, run again")
    part.replace(dst)
    log(f"  {dst.name}: ok" + (f" (resumed at {have} bytes)" if have else ""))
    return True


def fetch(root: Path, api: str = API, log=print) -> list[Path]:
    """Every file of the record into root/raw, checked; every zip unzipped into root/extracted."""
    raw, extracted = root / "raw", root / "extracted"
    raw.mkdir(parents=True, exist_ok=True)
    extracted.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(api, timeout=60) as r:
        record = json.load(r)
    (root / "record.json").write_text(json.dumps(record, indent=1))
    files = record["files"]
    # The list as files.tsv too (url, name, checksum), as lab/DATA.md describes.
    (root / "files.tsv").write_text("".join(f"{f['links']['self']}\t{f['key']}\t{f['checksum']}\n" for f in files))
    log(f"record {record.get('id', RECORD)}: {len(files)} files")
    out = []
    for f in files:
        algo, _, want = f["checksum"].partition(":")
        if algo != "md5":
            raise SystemExit(f"{f['key']}: checksum {algo}, expected md5")
        dst = raw / f["key"]
        if not download(f["links"]["self"], dst, want, log):
            log(f"  {dst.name}: have it")
        out.append(dst)
        done = extracted / f".{dst.name}.unzipped"
        if dst.suffix == ".zip" and not done.exists():
            with zipfile.ZipFile(dst) as z:
                z.extractall(extracted / dst.stem)
            done.write_text(want)
            log(f"  {dst.name}: unzipped")
    return out
