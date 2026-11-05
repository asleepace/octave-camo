# Docs

The research and planning behind octave-camo. The user-facing overview is the
[README](../README.md); what is and isn't covered is the [threat model](../THREAT_MODEL.md).

| Doc | What it is |
| --- | --- |
| [ACOUSTICS.md](ACOUSTICS.md) | How the check finds tones, and why: windows, integration, thresholds, measured sensitivity |
| [EXPERIMENTS.md](EXPERIMENTS.md) | The lab notebook: each experiment, its numbers, what it changed |
| [PLAN.md](PLAN.md) | The order of work: done, now, next |
| [IDEAS.md](IDEAS.md) | The backlog, and sparks from the data |
| [RESEARCH.md](RESEARCH.md) | A survey of related work and what it means for us |
| [SOURCES.md](SOURCES.md) | Every source, with a key to cite it by and how closely it was checked |

The tools for the experiments are in [lab/](../lab/README.md) (Python, recorder sessions with
ADS-B ground truth, never committed) and [harness/](../harness/README.md) (TypeScript attackers and
the benchmark gate CI runs).
