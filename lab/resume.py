"""Resumable lab runs: a job list run on a process pool, one JSON line appended per finished job,
and done jobs skipped on restart (CLAUDE.md, "Long runs must be resumable").

Each job is keyed by its index in the list plus a hash of its arguments. A restart with a changed
job list is refused rather than mixing results from two lists, and a file holding one key twice
(once, a key shared by several jobs made a resume skip work) is refused too.

    rows = resume.run(fn, jobs, path)       # rows in job order, each with its "_key"
"""
from __future__ import annotations

import hashlib
import json
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Callable, Sequence

KEY = "_key"


def job_key(i: int, job) -> str:
    """The job's index and a short hash of its arguments: unique, and it changes if the job does."""
    blob = json.dumps(job, sort_keys=True, default=repr).encode()
    return f"{i}:{hashlib.sha1(blob).hexdigest()[:12]}"


def load(path: Path) -> dict[str, dict]:
    """The rows already written, by key. Refuses a file with a key twice. A partly written last line
    (a worker killed mid-write) is dropped, and its job runs again."""
    rows: dict[str, dict] = {}
    if not path.exists():
        return rows
    lines = path.read_text().splitlines()
    for n, line in enumerate(lines):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            if n == len(lines) - 1:
                break
            raise SystemExit(f"{path}: line {n + 1} isn't JSON")
        k = r.get(KEY)
        if k is None:
            raise SystemExit(f"{path}: line {n + 1} has no {KEY}: not written by lab.resume")
        if k in rows:
            raise SystemExit(f"{path}: key {k} appears twice: refusing to resume from it")
        rows[k] = r
    return rows


def run(fn: Callable, jobs: Sequence, path: Path, workers: int = 2, log: Callable[[str], None] = print) -> list[dict]:
    """fn(job) for every job not already in path, appending each result (a dict) as it finishes.
    Returns every job's row in job order."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = [job_key(i, j) for i, j in enumerate(jobs)]
    done = load(path)
    by_index = {k.split(":")[0]: k for k in keys}
    for k in done:
        if k not in keys:
            i = k.split(":")[0]
            why = "its arguments changed" if i in by_index else "it isn't in the job list"
            raise SystemExit(f"{path}: job {k} is done but {why}: use a new results file")
    if path.exists() and path.read_text() and not path.read_text().endswith("\n"):
        # Drop a partly written last line before appending.
        text = path.read_text()
        path.write_text(text[: text.rfind("\n") + 1])
    todo = [(k, j) for k, j in zip(keys, jobs) if k not in done]
    log(f"{len(jobs)} jobs, {len(jobs) - len(todo)} done, {len(todo)} to do ({path.name})")
    with path.open("a") as f:
        def write(k, r):
            r = {**r, KEY: k}
            f.write(json.dumps(r) + "\n")
            f.flush()
            done[k] = r
        if workers <= 1:
            for k, j in todo:
                write(k, fn(j))
        else:
            with ProcessPoolExecutor(workers) as pool:
                futures = {pool.submit(fn, j): k for k, j in todo}
                for fu in as_completed(futures):
                    write(futures[fu], fu.result())
    return [done[k] for k in keys]
