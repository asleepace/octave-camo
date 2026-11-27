"""The place search scored on our sessions: the judges' calibration on plane-free noise, and the
session check of cloaked copies (docs/EXPERIMENTS.md, "The two-window cloak on our sessions", and
"The new holdout"). The #16 holdout is scored by these two commands.

    python3 -m lab session-calibrate [--attackers P0/1,PM0/1,PL0/1] [--holdout] [--sessions a,b]
    python3 -m lab session-check <copy-tag | name=tag,tag …> [--attackers …] [--holdout] [--sessions a,b]

A copy tag is a `lab trackfill` file name without the session and `.wav`: `full-tracks` is
`$LAB_DATA/cloaked/<session>-full-tracks.wav`, `full-tracks-s8` its seed-8 copy. `name=tag,tag`
puts several tags (two seeds) under one name; each session's copies under it are averaged before
sessions are compared. The first name is the reference the others are paired against.

Sessions are the tuning ones unless `--holdout` is given, which scores the held-out ones
(`corpus.is_holdout`) instead. A held-out session named with `--sessions` is refused without it.

Only aggregates are kept and printed: p, p_low and excess bits per audio and attacker, never a
position. Rows carry the session id's last six characters.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np

from . import corpus, locate, zenodo

JUDGES = ("P0/1", "PM0/1", "PL0/1")       # docs/EXPERIMENTS.md, "The new holdout": the judges
FOUND_P = 0.05                            # the place is given away at p ≤ 0.05
KINDS = zenodo.CAL_KINDS                  # ("white", "pink")
MEAN_P = (0.40, 0.60)                     # a calibrated judge's mean p on noise


def sessions(holdout: bool, named: list[str] | None = None) -> list[str]:
    """The sessions to score: `named`, or every tuning session; with `holdout`, the held-out ones.
    A held-out session is scored only on purpose (--holdout)."""
    if named:
        held = [s for s in named if corpus.is_holdout(s)]
        if held and not holdout:
            raise SystemExit(f"{held[0]} is in the holdout (corpus.is_holdout): pass --holdout to score it, "
                             "and only once the rule it decides is committed")
        return list(named)
    if holdout:
        return [s for s in corpus.all_ids(holdout=True) if corpus.is_holdout(s)]
    return corpus.all_ids()


def noise_seed(i: int, kind: str) -> int:
    """The seed of session i's noise clip: 2000 + 10·i, plus 1 for pink."""
    return 2000 + 10 * i + (kind == "pink")


def noise_clip(x: np.ndarray, sr: int, kind: str, seed: int) -> np.ndarray:
    """Plane-free noise as long as the session's audio, scaled to its standard deviation."""
    y = zenodo.noise(len(x), sr, kind, seed)
    return y * (np.std(x) / np.std(y))


def _summary(r: dict) -> dict:
    """What a row keeps of one locate result."""
    return {"p": r["p"], "p_low": r["p_low"], "excess_bits": r["excess_bits"]}


def calibrate_one(job: tuple) -> dict:
    """One noise clip (job: session, its index, noise kind, attackers), scored against the
    session's own aircraft by each attacker."""
    from . import detect
    sid, i, kind, attackers = job
    locate.whitened = lambda name, x, sr, prm: detect.whiten(x, sr, prm)   # noise: no disk cache
    _, x, sr = corpus.load(sid)
    seed = noise_seed(i, kind)
    y = noise_clip(x, sr, kind, seed)
    by = {}
    for a in attackers:
        (r,) = locate.locate(sid, [(f"noise-{kind}", y)], sr, attacker=a)
        by[a] = _summary(r)
    return {"sid": sid[-6:], "kind": kind, "seed": seed, "by": by}


def calibration_jobs(sids: list[str], attackers) -> list[tuple]:
    return [(sid, i, kind, list(attackers)) for i, sid in enumerate(sids) for kind in KINDS]


def binomial_limit(n: int, rate: float = FOUND_P, q: float = 0.975) -> int:
    """The most clips at p ≤ 0.05 a calibrated attacker gives, at the binomial 97.5 % point."""
    from scipy.stats import binom
    return int(binom.ppf(q, n, rate)) if n else 0


def calibration_summary(rows: list[dict], attackers) -> dict:
    """Per attacker: scorable clips (p < 1), clips at p ≤ 0.05 and ≤ 0.01, mean p, and whether it
    passes (p ≤ 0.05 within the binomial limit, mean p within MEAN_P). Under "any": clips scorable
    by at least one attacker, and how many any of them puts at p ≤ 0.05 (the chance rate when a
    copy counts as leaked to any judge), with its binomial se."""
    out = {}
    for a in attackers:
        p = np.array([r["by"][a]["p"] for r in rows], float)
        p = p[p < 1]
        n = len(p)
        limit = binomial_limit(n)
        mean = float(p.mean()) if n else math.nan
        out[a] = {"scorable": n, "clips": len(rows), "p05": int((p <= FOUND_P).sum()), "p01": int((p <= 0.01).sum()),
                  "mean_p": mean, "limit": limit,
                  "passes": bool(n and (p <= FOUND_P).sum() <= limit and MEAN_P[0] <= mean <= MEAN_P[1])}
    scorable = [r for r in rows if any(r["by"][a]["p"] < 1 for a in attackers)]
    k = sum(any(r["by"][a]["p"] <= FOUND_P for a in attackers) for r in scorable)
    n = len(scorable)
    rate = k / n if n else math.nan
    out["any"] = {"scorable": n, "found": k, "rate": rate,
                  "se": math.sqrt(rate * (1 - rate) / n) if n else math.nan}
    return out


def calibration_table(summ: dict, attackers) -> str:
    lines = ["| attacker | p ≤ 0.05 (limit) | p ≤ 0.01 | mean p | passes |", "| --- | ---: | ---: | ---: | --- |"]
    for a in attackers:
        s = summ[a]
        lines.append(f"| {a} | {s['p05']} / {s['scorable']} ({s['limit']}) | {s['p01']} | {s['mean_p']:.2f} | "
                     f"{'yes' if s['passes'] else 'no'} |")
    s = summ["any"]
    lines.append(f"\nAny of {', '.join(attackers)}: p ≤ 0.05 on {s['found']} of {s['scorable']} clips, "
                 f"{100 * s['rate']:.0f} ± {100 * s['se']:.0f} % (binomial se). "
                 f"{summ[attackers[0]]['clips']} clips in all.")
    return "\n".join(lines)


# --- The session check -------------------------------------------------------------------------

def parse_groups(words: list[str]) -> dict[str, list[str]]:
    """`tag` or `name=tag,tag` → {name: [tags]}, in the order given."""
    groups: dict[str, list[str]] = {}
    for w in words:
        name, eq, tags = w.partition("=")
        tags = tags.split(",") if eq else [name]
        if not name or not all(tags) or name in groups or name == "original":
            raise SystemExit(f"session-check: bad copy group {w!r} (a tag, or name=tag,tag; names unique, not 'original')")
        groups[name] = tags
    if not groups:
        raise SystemExit("session-check: name at least one copy tag (e.g. full-tracks)")
    return groups


def copy_path(sid: str, tag: str) -> Path:
    return corpus.DATA / "cloaked" / f"{sid}-{tag}.wav"


def check_one(job: tuple) -> dict:
    """One session (job: session, copy tags, attackers): the original and each copy, aligned to
    it, located by each attacker without the loudness term."""
    from . import common
    sid, tags, attackers = job
    audios, sr = common.with_copies(sid, [str(copy_path(sid, t)) for t in tags])
    audios = [("original", audios[0][1])] + [(t, y) for t, (_, y) in zip(tags, audios[1:])]
    by = {}
    for a in attackers:
        rs = locate.locate(sid, audios, sr, envelope=False, attacker=a)
        by[a] = {r["name"]: _summary(r) for r in rs}
    return {"sid": sid[-6:], "by": by}


def check_jobs(sids: list[str], groups: dict[str, list[str]], attackers) -> list[tuple]:
    """One job per session. Refuses to start if any session lacks a named copy."""
    tags = [t for ts in groups.values() for t in ts]
    missing = [copy_path(s, t).name for s in sids for t in tags if not copy_path(s, t).exists()]
    if missing:
        raise SystemExit(f"session-check: {len(missing)} copies missing in {corpus.DATA / 'cloaked'} "
                         f"(lab trackfill makes them), e.g. {', '.join(missing[:3])}")
    return [(sid, tags, list(attackers)) for sid in sids]


def mean_se(v) -> tuple[float, float, int]:
    """Mean, its standard error (sample sd / √n) and n, ignoring NaN."""
    v = np.asarray(v, float)
    v = v[np.isfinite(v)]
    n = len(v)
    if n == 0:
        return math.nan, math.nan, 0
    return float(v.mean()), float(v.std(ddof=1) / math.sqrt(n)) if n > 1 else math.nan, n


def check_summary(rows: list[dict], groups: dict[str, list[str]], attackers) -> dict:
    """Per attacker, over the sessions whose original it can score (p < 1): originals found
    (p ≤ 0.05); per copy group, copies found and holes (p_low ≤ 0.05) of the copies; excess bits
    by session (each session's copies in a group averaged), mean ± se; and each group minus the
    first, paired by session. Under "any": copies found by any of the attackers, over sessions at
    least one of them can score."""
    names = list(groups)
    out = {}
    for a in attackers:
        rs = [r for r in rows if r["by"][a]["original"]["p"] < 1]
        o = np.array([r["by"][a]["original"]["excess_bits"] for r in rs], float)
        s = {"sessions": len(rs), "originals_found": sum(r["by"][a]["original"]["p"] <= FOUND_P for r in rs),
             "original_bits": mean_se(o), "groups": {}}
        per = {}
        for g in names:
            cs = [r["by"][a][t] for r in rs for t in groups[g]]
            per[g] = np.array([np.mean([r["by"][a][t]["excess_bits"] for t in groups[g]]) for r in rs], float)
            s["groups"][g] = {"copies": len(cs), "found": sum(c["p"] <= FOUND_P for c in cs),
                              "holes": sum(c["p_low"] <= FOUND_P for c in cs), "bits": mean_se(per[g]),
                              "minus_first": mean_se(per[g] - per[names[0]]) if g != names[0] else None}
        out[a] = s
    rs = [r for r in rows if any(r["by"][a]["original"]["p"] < 1 for a in attackers)]
    found = lambda name: sum(any(r["by"][a][name]["p"] <= FOUND_P for a in attackers) for r in rs)
    out["any"] = {"sessions": len(rs), "originals_found": found("original"),
                  "groups": {g: {"copies": len(rs) * len(groups[g]), "found": sum(found(t) for t in groups[g])} for g in names}}
    return out


def _pm(m: tuple) -> str:
    mean, se, _ = m
    return f"{mean:+.2f} ± {se:.2f}" if np.isfinite(se) else f"{mean:+.2f}"


def check_table(summ: dict, groups: dict[str, list[str]], attackers) -> str:
    names = list(groups)
    head = ["attacker", "sessions", "originals found", *(f"{g} copies found" for g in names),
            *(f"{g} holes" for g in names), "excess bits: original", *(f"{g}" for g in names),
            *(f"{g} − {names[0]}" for g in names[1:])]
    lines = ["| " + " | ".join(head) + " |", "| --- |" + " ---: |" * (len(head) - 1)]
    for a in attackers:
        s = summ[a]
        G = s["groups"]
        cells = [a, str(s["sessions"]), str(s["originals_found"]),
                 *(f"{G[g]['found']} / {G[g]['copies']}" for g in names),
                 *(f"{G[g]['holes']}" for g in names),
                 _pm(s["original_bits"]), *(_pm(G[g]["bits"]) for g in names),
                 *(f"{_pm(G[g]['minus_first'])} ({G[g]['minus_first'][0] / G[g]['minus_first'][1]:+.1f} se)"
                   if np.isfinite(G[g]["minus_first"][1]) and G[g]["minus_first"][1] > 0 else _pm(G[g]["minus_first"])
                   for g in names[1:])]
        lines.append("| " + " | ".join(cells) + " |")
    s = summ["any"]
    lines.append(f"\nAny of {', '.join(attackers)} ({s['sessions']} sessions): originals found {s['originals_found']}; "
                 + "; ".join(f"{g} copies found {v['found']} of {v['copies']}" for g, v in s["groups"].items()) + ".")
    lines.append("Found: p ≤ 0.05. Holes: p_low ≤ 0.05. Excess bits: mean ± se by session (sample sd / √n), "
                 "each session's copies in a group averaged; differences paired by session.")
    return "\n".join(lines)
