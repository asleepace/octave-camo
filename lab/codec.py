"""What a posted video's audio goes through after the cloak: the page's export, then a platform's
re-encode (OPEN_QUESTIONS.md, "Are the lab's scores what a posted video would give?").

The page writes mono AAC-LC at 160 kbps (web/src/media.ts, AUDIO_BITRATE). Browsers without a native
AAC encoder use the WASM build of FFmpeg's encoder, which is ffmpeg's `aac` here; Chrome and Safari
with a native encoder use the platform's own (AudioToolbox on Apple), which this can't reproduce.
What a platform does on upload isn't published and changes; the chains after "page" are
stand-ins of the common kinds (AAC at a lower rate and 44.1 kHz, or Opus), not any one service.

Every chain decodes back to the input's rate and length, aligned: ffmpeg trims the encoder's
priming samples, so sample i out is sample i in (checked by `Codec` in lab/tests).
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

# Each step: (ffmpeg encoder options, container suffix). The decoded audio feeds the next step.
PAGE = (["-c:a", "aac", "-b:a", "160k", "-ac", "1"], ".m4a")
CHAINS: dict[str, list[tuple[list[str], str]]] = {
    "raw": [],
    "page": [PAGE],
    "aac128": [PAGE, (["-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2"], ".m4a")],
    "aac64": [PAGE, (["-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "1"], ".m4a")],
    "opus96": [PAGE, (["-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-ac", "2"], ".ogg")],
}


def available() -> bool:
    return shutil.which("ffmpeg") is not None


def reencode(x: np.ndarray, sr: int, chain: str) -> np.ndarray:
    """`x` (mono float) through `chain`, decoded to mono at `sr`, cut or padded to len(x)."""
    steps = CHAINS[chain]
    if not steps:
        return x
    with tempfile.TemporaryDirectory() as tmp:
        cur = Path(tmp) / "in.wav"
        sf.write(cur, x, sr, subtype="FLOAT")
        for i, (opts, suffix) in enumerate(steps):
            enc = Path(tmp) / f"s{i}{suffix}"
            dec = Path(tmp) / f"s{i}.wav"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(cur), *opts, str(enc)], check=True)
            # Decoded mono at the input's rate: stereo halves are averaged (dual mono, so the same).
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(enc), "-ac", "1", "-ar", str(sr),
                            "-c:a", "pcm_f32le", str(dec)], check=True)
            cur = dec
        y, _ = sf.read(cur, dtype="float64")
    y = y if y.ndim == 1 else y.mean(1)
    return y[: len(x)] if len(y) >= len(x) else np.pad(y, (0, len(x) - len(y)))
