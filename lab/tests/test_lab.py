"""Lab invariants: python3 -m unittest discover -s lab/tests -t .   (from the repo root)

No session data needed: everything here is synthetic.
"""
from __future__ import annotations

import unittest

import numpy as np
from scipy.signal import firwin, lfilter

from lab import common, corpus, detect, locate

SR = 16_000


def tone_in_noise(f0=700.0, seconds=30.0, snr_db_hz=20.0, seed=1):
    rng = np.random.default_rng(seed)
    n = int(SR * seconds)
    a = np.sqrt(4 * 10 ** (snr_db_hz / 10) / SR)          # same convention as the Swift scenes
    return rng.normal(0, 1, n) + a * np.sin(2 * np.pi * f0 * np.arange(n) / SR + 0.3)


def factor(tt):
    """A smooth fall, 1.15 → 0.85 around t = 30 s: the shape of a pass."""
    return 1.15 - 0.3 / (1 + np.exp(-(tt - 30) / 4))


def passing_tone(f0=900.0, snr_db_hz=16.0, seed=3, seconds=60):
    rng = np.random.default_rng(seed)
    t = np.arange(SR * seconds) / SR
    phase = 2 * np.pi * np.cumsum(f0 * factor(t)) / SR
    return rng.normal(0, 1, len(t)) + np.sqrt(4 * 10 ** (snr_db_hz / 10) / SR) * np.sin(phase)


P_KNOWN = detect.Params(band=(300.0, 2000.0), broadband_aware=True)


def known(x):
    """The known-path attacker: (z against the curve at wrong times, rest frequency, offset)."""
    f, tt, L = detect.whiten(x, SR, P_KNOWN)
    A, f0s, win = L - L.mean(), np.arange(500, 1500, 2.0), (5, 55)
    best, rest, off = detect.known_path(f, tt, A, factor, f0s, win)
    nulls = np.array([detect.known_path(f, tt, A, lambda u, s=s: factor(u - s), f0s, win)[0] for s in (-30, -24, -18, 18, 24, 30)])
    return (best - nulls.mean()) / nulls.std(), rest, off


class WhiteningIsLevelBlind(unittest.TestCase):
    """Why boosting can't help a detector and filtering can't hide from one: each bin is
    compared with its own running median, so a gain per frequency cancels."""

    def test_a_boost_changes_nothing(self):
        p = detect.Params(band=(300.0, 2000.0))
        x = tone_in_noise()
        _, _, a = detect.whiten(x, SR, p)
        _, _, b = detect.whiten(100 * x, SR, p)
        np.testing.assert_allclose(a, b, atol=1e-5)

    def test_a_filter_40_dB_deep_over_the_whole_sweep_doesnt_hide_it(self):
        x = passing_tone(snr_db_hz=20)
        h = firwin(2047, [700, 1100], fs=SR)                  # band-pass over the sweep (765–1035 Hz)
        stop = np.zeros_like(h)
        stop[len(h) // 2] = 1
        y = lfilter(stop - 0.99 * h, 1, x)                     # band-stop, ~40 dB: attenuated, not removed
        before, rest_b, _ = known(x)
        after, rest_a, _ = known(y)
        self.assertGreater(before, 5)
        self.assertGreater(after, 0.7 * before, "whitening should bring the attenuated tone back")
        self.assertAlmostEqual(rest_a, rest_b, delta=10)


class Geometry(unittest.TestCase):
    def straight(self, speed=140.0, distance=2_000.0, height=1_000.0):
        te = np.arange(-60, 60, 0.1)
        q = np.stack([speed * te, np.full_like(te, distance), np.full_like(te, height)], 1)
        v = np.tile([speed, 0.0, 0.0], (len(te), 1))
        return {"speed_of_sound": 343.0, "duration_s": 60.0, "tracks": {"abc123": (te, q, v)}}

    def test_doppler_factor_and_sound_delay(self):
        geo = self.straight()
        heard, fac, tc, rmin = locate.curves(geo, np.zeros(2))["abc123"]
        r = np.hypot(2_000, 1_000)
        self.assertAlmostEqual(rmin, r, delta=20)
        self.assertAlmostEqual(tc, r / 343, delta=0.2)          # emitted at 0, heard r/c later
        i = int(np.argmin(np.abs(heard - tc)))
        self.assertAlmostEqual(fac[i], 1.0, delta=0.002)         # no radial speed at closest
        self.assertGreater(fac[0], 1.2)                          # approaching: higher
        self.assertLess(fac[-1], 0.85)                           # receding: lower
        self.assertTrue(np.all(np.diff(fac) < 1e-9))             # a straight pass only falls

    def test_moving_the_listener_moves_the_curve(self):
        geo = self.straight()
        _, _, tc0, r0 = locate.curves(geo, np.zeros(2))["abc123"]
        _, _, tc1, r1 = locate.curves(geo, np.array([1_400.0, 0.0]))["abc123"]
        self.assertAlmostEqual(tc1 - tc0, 10.0, delta=0.5)       # 1.4 km along the track at 140 m/s
        self.assertAlmostEqual(r1, r0, delta=20)

    def test_grid_has_the_truth_and_combine_ignores_silence(self):
        g = locate.grid(1_000, 500)
        self.assertTrue(np.any(np.all(g == 0, axis=1)))
        z = np.array([[1.0, np.nan], [np.nan, np.nan], [2.0, -1.0]])
        np.testing.assert_allclose(locate.combine(z), [1.0, 0.0, 1.0])


class KnownPath(unittest.TestCase):
    def test_finds_a_faint_tone_along_its_curve(self):
        z, rest, off = known(passing_tone())
        self.assertGreater(z, 5)
        # Rest frequency and timing trade off along the curve: a few percent and seconds.
        self.assertAlmostEqual(rest, 900, delta=30)
        self.assertLessEqual(abs(off), 3.0)


class Plumbing(unittest.TestCase):
    def test_cache_key_follows_the_audio(self):
        x = np.zeros(100)
        y = x.copy()
        y[50] = 1e-3
        p = detect.Params()
        self.assertNotEqual(common.cache_key("a", p, x), common.cache_key("a", p, y))
        self.assertEqual(common.cache_key("a", p, x), common.cache_key("a", p, x.copy()))

    def test_align_undoes_an_encoder_delay(self):
        x = tone_in_noise(seconds=31, seed=4)
        y = np.concatenate([np.zeros(1_234), x])[: len(x)]
        np.testing.assert_allclose(common.align(x, y, SR)[5_000:-5_000], x[5_000:-5_000])

    def test_only_positions_pass_the_plausibility_check(self):
        self.assertTrue(corpus._plausible(37.0, -122.0, 3_000))
        self.assertTrue(corpus._plausible(37.0, -122.0, None))
        self.assertFalse(corpus._plausible(1_290.0, -122.0, 3_000))     # not a position row
        self.assertFalse(corpus._plausible(37.0, -122.0, 321_250))


if __name__ == "__main__":
    unittest.main()
