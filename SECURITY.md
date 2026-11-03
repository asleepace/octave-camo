# Security policy

octave-camo is a proof of concept. It reduces location leakage from a video's sound and picture;
it does not guarantee anonymity. Please read [THREAT_MODEL.md](THREAT_MODEL.md) before relying on it.

## What counts as a vulnerability

Anything that makes a cloaked file reveal more than this project claims, or makes the tool itself
leak. For example:

- an attack that recovers location, time or grid region from a file cloaked with the default
  settings, beyond what [THREAT_MODEL.md](THREAT_MODEL.md) lists as known gaps;
- metadata, extra tracks or other side data surviving into the saved file;
- the web app sending anything (audio, video, file names, analytics) off the device, or loading
  code from anywhere but its own origin;
- a fingerprint the cloak itself adds that narrows down where a recording was made (like the
  60 Hz notch pattern fixed in November 2026);
- crashes or hangs that can be triggered by a crafted media file.

Ordinary bugs, feature requests and "this sounds different" reports are welcome as regular
issues.

## How to report

Use GitHub's private vulnerability reporting: **Security → Report a vulnerability** on
[asleepace/octave-camo](https://github.com/asleepace/octave-camo/security/advisories/new).
Please include:

- what you recovered, and from what (a synthetic clip you can share is ideal);
- the commit or deployed version you tested;
- steps or code to reproduce.

**Never attach a real recording that contains your own location**, and never post one in a public
issue. If a real clip is needed to reproduce, say so in the report and we'll arrange a private way
to share it.

## What to expect

- Acknowledgement within a few days.
- A fix or a documented limitation, with credit if you want it. Attacks that hold up become
  benchmark clips, so the CI gate keeps them fixed.
- Coordinated disclosure: please give us a reasonable window (up to 90 days) before publishing.
  We're happy to publish sooner once a fix ships.

There is no bug bounty.
