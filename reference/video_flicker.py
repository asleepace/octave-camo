"""
Mains flicker in video: the picture's copy of the ENF clock, found and removed blind.

Lights on AC power flicker at twice the mains frequency (100 or 120 Hz). A rolling-shutter camera
reads rows top to bottom over the readout time, so each row samples a different moment and the
flicker becomes horizontal bands. With F the flicker frequency, t_k the frame time and readout the
time to read all rows, row r of frame k sees (log brightness)

    m · cos(2π F (t_k + readout · r / R) + φ(t))

where φ(t) drifts with the grid frequency: the ENF trace an attacker wants. The spatial frequency is
C = F · readout cycles per frame height, so each frame's row profile is projected onto
e^{-i2πC r/R}, and a temporal DFT over frames at F turns the sequence into a line in (F, C).
That's the attacker's search. The defender runs the same search, then estimates the band's
slowly varying complex amplitude and divides it out of every row.

    python3 video_flicker.py synth out.mp4 --flicker 120 --fps 30 --readout 0.5 --depth 0.03
    python3 video_flicker.py scan clip.mov
"""
import argparse
import json
import subprocess
import sys

import numpy as np

ROWS = 120
STRIPS = 6


def probe_fps(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=avg_frame_rate", "-of", "default=nw=1:nk=1", path], capture_output=True, text=True,
                         check=True).stdout.strip()
    num, den = out.split("/")
    return float(num) / float(den)


def row_means(path, rows=ROWS, strips=STRIPS, seconds=None):
    """Log mean brightness per row band and column strip, frames × strips × rows (gamma-encoded luma)."""
    cmd = ["ffmpeg", "-v", "error", "-i", path]
    if seconds:
        cmd += ["-t", str(seconds)]
    cmd += ["-map", "0:v:0", "-vf", f"scale={strips}:{rows}:flags=area,format=gray", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, dtype=np.uint8).reshape(-1, rows, strips).astype(np.float64)
    return np.log(frames.transpose(0, 2, 1) / 255 + 1 / 255)


def detrend(y):
    """Per profile (last axis = rows): remove the mean and a quadratic trend (sky-to-ground gradients)."""
    R = y.shape[-1]
    u = np.linspace(-1, 1, R)
    basis = np.stack([np.ones(R), u, u * u], axis=1)
    flat = y.reshape(-1, R)
    coef, *_ = np.linalg.lstsq(basis, flat.T, rcond=None)
    return (flat - (basis @ coef).T).reshape(y.shape)


class Flicker:
    def __init__(self, mains=(50, 60), readout=(0.3, 0.95), span_hz=0.6, step_hz=0.02, c_step=0.04,
                 segment_s=4.0, smooth_s=0.5, max_depth=0.05, detect_z=60.0, static_s=20.0):
        self.mains, self.readout, self.span_hz, self.step_hz = mains, readout, span_hz, step_hz
        self.c_step, self.segment_s, self.smooth_s = c_step, segment_s, smooth_s
        self.max_depth, self.detect_z, self.static_s = max_depth, detect_z, static_s

    def projections(self, y, Cs, fps=None):
        """Band phasors per frame, K × NC. y is frames × strips × rows.

        Flicker brightens a whole row evenly, so it's the part the column strips share: take the
        median over strips (real and imaginary parts), which scene structure mostly doesn't survive.
        Then (for scanning) remove each phasor's long-term mean: whatever doesn't move over
        `static_s` is scene, or flicker so steady it carries no clock.
        """
        R = y.shape[-1]
        w = np.hanning(R)
        r = np.arange(R)
        basis = w[:, None] * np.exp(-2j * np.pi * np.outer(r, Cs) / R)       # R × NC
        p = detrend(y) @ basis                                               # K × S × NC
        c = np.median(p.real, axis=1) + 1j * np.median(p.imag, axis=1)
        if fps is not None:
            L = max(1, int(round(self.static_s * fps)))
            kernel = np.ones(L) / L
            slow = np.stack([np.convolve(c[:, j], kernel, mode="same") / np.convolve(np.ones(len(c)), kernel, mode="same")
                             for j in range(c.shape[1])], axis=1)
            c = c - slow
        return c, w.sum()

    def scan(self, y, times, fps):
        T = 1 / fps
        Fs_all = [2 * m for m in self.mains]
        # Scan a wider spatial range than physically plausible: each temporal-frequency row is
        # judged against its own spread over C (scene motion is broad in C; a band is narrow).
        Cs = np.arange(0.5, 2 * max(Fs_all) * self.readout[1] * T + 1e-9, self.c_step)
        c, _ = self.projections(y, Cs, fps)
        seg = max(4, int(round(self.segment_s * fps)))
        best = None
        for F0 in Fs_all:
            Fs = F0 + np.arange(-self.span_hz, self.span_hz + 1e-9, self.step_hz)
            E = np.exp(-2j * np.pi * np.outer(Fs, times))                      # NF × K
            P = np.zeros((len(Fs), len(Cs)))
            for s in range(0, len(times) - seg + 1, seg):
                P += np.abs(E[:, s:s + seg] @ c[s:s + seg]) ** 2
            med = np.median(P, axis=1, keepdims=True)
            mad = np.median(np.abs(P - med), axis=1, keepdims=True) * 1.4826 + 1e-30
            Z = (P - med) / mad
            valid = (Cs >= F0 * self.readout[0] * T - 1e-9) & (Cs <= F0 * self.readout[1] * T + 1e-9)
            Z[:, ~valid] = -np.inf
            i, j = np.unravel_index(np.argmax(Z), Z.shape)
            if best is None or Z[i, j] > best["z"]:
                best = dict(z=float(Z[i, j]), flicker=float(Fs[i]), cycles=float(Cs[j]), readout=float(Cs[j] / Fs[i]))
        best["detected"] = best["z"] > self.detect_z
        return best

    def model(self, y, times, flicker, cycles):
        """Smoothed band estimate (log brightness), frames × rows, depth capped."""
        R = y.shape[-1]
        c, wsum = self.projections(y, np.array([cycles]))
        a = (2 / wsum) * c[:, 0] * np.exp(-2j * np.pi * flicker * times)
        fps = 1 / np.median(np.diff(times))
        L = max(1, int(round(self.smooth_s * fps)))
        kernel = np.ones(L) / L
        a = np.convolve(a, kernel, mode="same")
        mag = np.abs(a)
        a = np.where(mag > self.max_depth, a * self.max_depth / np.maximum(mag, 1e-12), a)
        phase = np.exp(2j * np.pi * (np.outer(flicker * times, np.ones(R)) + np.outer(np.ones(len(times)), cycles * np.arange(R) / R)))
        return np.real(a[:, None] * phase)[:, None, :]          # same model for every strip

    def clean(self, y, times, fps, passes=2):
        """Iteratively remove detected flicker components. Returns corrected y, total model, scans."""
        total = np.zeros_like(y)
        scans = []
        for _ in range(passes):
            s = self.scan(y - total, times, fps)
            scans.append(s)
            if not s["detected"]:
                break
            total += self.model(y - total, times, s["flicker"], s["cycles"])
        return y - total, total, scans


def synth(out, flicker, fps, readout, depth, seconds, drift_hz, size):
    """testsrc2 with rolling-shutter banding whose phase wanders like ENF."""
    w, h = size.split("x")
    period = 17.0
    # φ(t) = 2π ∫ δ dt with δ = drift·sin(2πt/period)  →  −drift·period·cos(2πt/period) (in cycles)
    expr = (f"clip(lum(X,Y)*(1+{depth}*cos(2*PI*({flicker}*(T+Y/H*{readout}/{fps})"
            f"-{drift_hz}*{period}*cos(2*PI*T/{period})))),0,255)")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={w}x{h}:rate={fps}",
                    "-t", str(seconds), "-vf", f"format=yuv420p,geq=lum='{expr}':cb='cb(X,Y)':cr='cr(X,Y)'",
                    "-c:v", "libx264", "-crf", "16", "-preset", "veryfast", "-pix_fmt", "yuv420p", out], check=True)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("synth")
    s.add_argument("out")
    s.add_argument("--flicker", type=float, default=120)
    s.add_argument("--fps", type=float, default=30)
    s.add_argument("--readout", type=float, default=0.5, help="fraction of the frame period")
    s.add_argument("--depth", type=float, default=0.03)
    s.add_argument("--seconds", type=float, default=20)
    s.add_argument("--drift", type=float, default=0.04, help="ENF wander amplitude, Hz")
    s.add_argument("--size", default="640x360")
    c = sub.add_parser("scan")
    c.add_argument("path")
    c.add_argument("--seconds", type=float)
    c.add_argument("--clean", action="store_true", help="also report the scan after removal")
    a = p.parse_args()
    if a.cmd == "synth":
        synth(a.out, a.flicker, a.fps, a.readout, a.depth, a.seconds, a.drift, a.size)
        return
    fps = probe_fps(a.path)
    y = row_means(a.path, seconds=a.seconds)
    times = np.arange(len(y)) / fps
    f = Flicker()
    result = {"frames": len(y), "fps": fps, "before": f.scan(y, times, fps)}
    if a.clean:
        yc, _, scans = f.clean(y, times, fps)
        result["passes"] = scans
        result["after"] = f.scan(yc, times, fps)
    json.dump(result, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
