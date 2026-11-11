"""Lab invariants: python3 -m unittest discover -s lab/tests -t .   (from the repo root)

No session data needed: everything here is synthetic.
"""
from __future__ import annotations

import unittest

import numpy as np
from scipy.signal import firwin, lfilter

from lab import common, corpus, detect, locate, zenodo

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
    z, _, rest, off = detect.known_path_z(f, tt, L - L.mean(), factor, np.arange(500, 1500, 2.0), (5, 55))
    return z, rest, off


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

    def test_envelope_scores_the_swell_where_it_was_heard(self):
        """Broadband noise swelling as a pass 1.5 km away predicts: the loudness score at the
        truth beats the same pass at wrong times, and beats a point far from the track (a nearby
        one can fit nearly as well: the swell's width pins distance only coarsely)."""
        speed, distance = 120.0, 1_500.0
        te = np.arange(-200, 200, 0.1)
        q = np.stack([speed * te, np.full_like(te, distance), np.full_like(te, 300.0)], 1)
        geo = {"speed_of_sound": 343.0, "duration_s": 120.0,
               "tracks": {"abc123": (te + 60, q, np.tile([speed, 0.0, 0.0], (len(te), 1)))}}
        heard, r = locate.ranges(geo, np.zeros(2))["abc123"]
        rng = np.random.default_rng(2)
        sr = 8_000
        t = np.arange(int(sr * 120)) / sr
        gain = 10 ** (np.interp(t, heard, -20 * np.log10(r)) / 20)
        x = rng.normal(0, 1, len(t)) * (0.05 + 300 * gain)        # a steady floor plus the swell
        scene = locate.EnvelopeScene(x, sr)
        s0, m, sd = scene.scores(heard, r, 0.0)
        self.assertGreater((s0 - m) / sd, 3)
        far_heard, far_r = locate.ranges(geo, np.array([0.0, -6_000.0]))["abc123"]
        s1, _, _ = scene.scores(far_heard, far_r, 0.0)
        self.assertTrue(np.isnan(s1) or s0 > s1, s1)

    def test_grid_has_the_truth_and_combine_ignores_silence(self):
        g = locate.grid(1_000, 500)
        self.assertTrue(np.any(np.all(g == 0, axis=1)))
        z = np.array([[1.0, np.nan], [np.nan, np.nan], [2.0, -1.0]])
        np.testing.assert_allclose(locate.combine(z), [1.0, 0.0, 1.0])


class PlaceSearch(unittest.TestCase):
    """The place search's scoring (lab/locate.py): the log-axis shortcut against the direct search,
    and the bits and ranks it reports."""

    def setUp(self):
        import tempfile
        from pathlib import Path
        self.tmp, self.data = tempfile.TemporaryDirectory(), corpus.DATA
        corpus.DATA = Path(self.tmp.name)           # the spectrogram cache, not the real data folder

    def tearDown(self):
        corpus.DATA = self.data
        self.tmp.cleanup()

    def test_log_axis_search_matches_the_direct_one(self):
        x = passing_tone(f0=900.0, snr_db_hz=12.0)
        scene = locate.Scene(x, SR, "test-place")
        rng = np.random.default_rng(5)
        got = []
        for k in range(60):
            mid, width, depth = rng.uniform(15, 45), rng.uniform(2, 8), rng.uniform(0.02, 0.3)
            fac = 1 + depth / 2 - depth / (1 + np.exp(-(scene.t - mid) / width))
            j = np.flatnonzero(np.abs(scene.t - mid) <= 25)
            fac_j = fac[j].copy()
            fac_j[: rng.integers(0, 40)] = np.nan                       # part of the curve unknown
            got.append((scene._best(j, fac_j), scene._best_direct(j, fac_j)))
        got = np.array(got)
        self.assertTrue(np.isfinite(got).all())
        err = got[:, 0] - got[:, 1]
        self.assertLess(abs(err.mean()), 0.01)                          # no bias either way
        # Rounding the factor to 0.2 % moves a curve by a fraction of a bin: small against how much
        # curves' scores differ (here about 0.3 of the spread; on a real session 95 % within 0.05 of 0.37).
        self.assertLess(np.percentile(abs(err), 95), 0.35 * got[:, 1].std())
        # On the true curve too (where the score is far above noise).
        j = np.flatnonzero(np.abs(scene.t - 30) <= 25)
        true = scene._best(j, factor(scene.t[j]))
        self.assertAlmostEqual(true, scene._best_direct(j, factor(scene.t[j])), delta=0.05 * true)

    def test_lines_count_each_line_once_and_add_up(self):
        # Two lines of an engine, 900 Hz and an unrelated 1370 Hz, along the same pass.
        x = passing_tone(f0=900.0, snr_db_hz=16.0) + passing_tone(f0=1370.0, snr_db_hz=16.0, seed=8) \
            - np.random.default_rng(8).normal(0, 1, int(SR * 60))   # one noise floor, not two
        scene = locate.Scene(x, SR, "test-lines")
        j = np.flatnonzero(np.abs(scene.t - 30) <= 25)
        prof = scene._profile(j, factor(scene.t[j]))
        one, two, three = (scene.lines_of(prof, k) for k in (1, 2, 3))
        self.assertAlmostEqual(one, scene._best(j, factor(scene.t[j])), places=6)
        self.assertAlmostEqual(one, np.nanmax(prof), places=6)
        # Every pick adds the noise floor (the best of ±2 bins is biased up); a line adds more.
        floor = np.nanmedian(prof)
        first, second, third = one - floor, two - one - floor, three - two - floor
        self.assertGreater(second, 0.5 * first)       # the second line counts, as much as the first
        self.assertLess(third, 0.3 * second)          # a third pick finds only noise
        # The wrong curve doesn't gain from more lines the way the true one does.
        wrong = scene._profile(j, factor(scene.t[j] + 12))
        self.assertGreater(two - scene.lines_of(wrong, 2), one - scene.lines_of(wrong, 1))

    def test_rank_bits(self):
        self.assertAlmostEqual(locate.rank_bits(545, 1089), 0.0)            # where a blind guess lands
        self.assertAlmostEqual(locate.rank_bits(1, 1089), np.log2(545))     # truth first
        self.assertLess(locate.rank_bits(1089, 1089), 0)                    # truth last
        self.assertGreater(locate.rank_bits(20, 1089), locate.rank_bits(26, 1089))


class NullBits(unittest.TestCase):
    def test_the_truth_always_hearing_the_aircraft_is_not_information(self):
        rng = np.random.default_rng(3)
        Z = np.full((1000, 1), np.nan)
        Z[:300, 0] = rng.normal(0, 1, 300)          # a third of the grid hears the aircraft
        truth = 0
        Z[truth, 0] = 1.2                           # a noise-sized z at the truth
        total = locate.combine(Z)
        rank = int((total > total[truth]).sum() + ((total == total[truth]).sum() + 1) // 2)
        bits = locate.rank_bits(rank, len(total))
        nb = locate.null_bits(Z, truth)
        self.assertGreater(bits, 2.5)               # the raw rank flatters it...
        self.assertGreater((nb >= bits).mean(), 0.05)   # ...but no-information audio gets that often
        self.assertGreater(nb.mean(), 0.5)          # and the baseline itself is above 0

    def test_a_hole_shows_from_the_bottom(self):
        rng = np.random.default_rng(4)
        Z = rng.normal(0, 1, (1000, 3))
        Z[0] = [-2.5, -2.5, -2.5]                   # removal left the truth below every wrong place
        total = locate.combine(Z)
        others = np.sort(np.delete(total, 0))
        low = locate.rank_bits(locate._rank(total[0], others, low=True), len(total))
        self.assertLess((locate.null_bits(Z, 0, low=True) >= low).mean(), 0.01)
        high = locate.rank_bits(locate._rank(total[0], others), len(total))
        self.assertGreater((locate.null_bits(Z, 0) >= high).mean(), 0.9)   # the top-down score misses it

    def test_ranks_count_ties_in_the_middle(self):
        others = np.array([0.0, 0.0, 0.0, 1.0])
        self.assertEqual(locate._rank(0.0, others), 1 + 2)       # one above; four tied (with itself) → middle
        self.assertEqual(locate._rank(0.0, others, low=True), 2)
        self.assertEqual(locate._rank(2.0, others), 1)

    def test_nothing_heard_at_the_truth_means_its_rank_is_fixed(self):
        Z = np.full((50, 2), np.nan); Z[10:, 0] = np.linspace(-2, 2, 40)
        nb = locate.null_bits(Z, 0)
        self.assertTrue(np.allclose(nb, nb[0]))


class PublicCorpus(unittest.TestCase):
    """lab/zenodo.py's pure parts, on a made-up traced curve (no data needed)."""

    def traced(self):
        t = np.arange(0, 50, 0.1707)
        rng = np.random.default_rng(1)
        return {"t": t, "f": 300 * factor(t + 5) + rng.normal(0, 2, len(t))}   # falls around t = 25 s

    def test_shape_finds_the_fall_and_normalises(self):
        t, fac, tc = zenodo.shape(self.traced())
        self.assertAlmostEqual(np.median(fac), 1.0, delta=0.01)
        self.assertAlmostEqual(tc, 25.0, delta=2.0)

    def test_expected_pass_is_what_the_engine_accepts(self):
        e = zenodo.expected_pass(self.traced(), zenodo.OFFSET_S, 60.0)
        t, f = np.array(e["times"]), np.array(e["factors"])
        self.assertTrue(np.all(np.diff(t) > 0))
        self.assertTrue(np.all((f > 0.5) & (f < 2)))
        self.assertLess(t[0], 0)                                   # covers the audio and beyond
        self.assertGreater(t[-1], 60)
        self.assertAlmostEqual(e["closest"], 25.0 + zenodo.OFFSET_S, delta=2.0)
        # Flat beyond the trace: the first and last factors are the trace's end values.
        _, fac, _ = zenodo.shape(self.traced())
        self.assertAlmostEqual(f[0], fac[0], places=5)
        self.assertAlmostEqual(f[-1], fac[-1], places=5)

    def test_wrong_place_rank_finds_its_own_pass_and_not_noise(self):
        # Six passes of clearly different geometries (depth and width of the fall), each traced for
        # 50 s. (A similar one, 0.35 deep and 6.5 s wide, ties the truth: a nearby place does.)
        t = np.arange(0, 50, 0.1707)
        geos = [(0.30, 4.0), (0.12, 6.0), (0.50, 2.0), (0.20, 9.0), (0.06, 5.0), (0.15, 2.0)]
        ps = [{"case": f"c{k}", "t": t, "f": 300 * (1 + d / 2 - d / (1 + np.exp(-(t - 25) / w)))}
              for k, (d, w) in enumerate(geos)]
        n = int(SR * (50 + 2 * zenodo.OFFSET_S))
        tt = np.arange(n) / SR
        rng = np.random.default_rng(4)
        _, fac, _ = zenodo.shape(ps[0])
        f = 700 * zenodo.flat_interp(tt - zenodo.OFFSET_S, t, fac)
        a = np.sqrt(4 * 10 ** (12 / 10) / SR)
        x = rng.normal(0, 1, n) + a * np.sin(2 * np.pi * np.cumsum(f) / SR)
        u, count = zenodo.u(locate.Scene(x, SR, "test:u:pass"), ps[0], ps, zenodo.OFFSET_S)
        self.assertEqual(count, 5 * len(zenodo.PLACE_OFFSETS_S))
        self.assertGreaterEqual(u, 0.95)                 # its own curve beats every wrong place's
        # Noise alone: no pass's rank is pinned to the top (each is one draw of a uniform rank).
        noise = [zenodo.u(locate.Scene(np.random.default_rng(10 + k).normal(0, 1, n), SR, f"test:u:noise{k}"),
                          ps[k], ps, zenodo.OFFSET_S)[0] for k in range(len(ps))]
        self.assertLess(np.mean(noise), 0.85)
        self.assertGreater(np.mean(noise), 0.15)


class Invariants(unittest.TestCase):
    """Properties the scoring relies on, on made-up numbers (no audio)."""

    def test_rank_is_uniform_when_the_truth_is_one_more_draw(self):
        rng = np.random.default_rng(0)
        u = np.array([locate.rank(rng.normal(), rng.normal(size=144)) for _ in range(4000)])
        self.assertAlmostEqual(u.mean(), 0.5, delta=0.02)
        self.assertAlmostEqual(np.mean(u >= 0.95), 0.05, delta=0.015)   # a 5 % tail is 5 % of clips
        self.assertAlmostEqual(np.mean(u <= 0.05), 0.05, delta=0.015)
        # Discrete draws (ties): halving them keeps it centred.
        d = np.array([locate.rank(float(rng.integers(3)), rng.integers(3, size=40).astype(float)) for _ in range(4000)])
        self.assertAlmostEqual(d.mean(), 0.5, delta=0.02)

    def test_rank_edges(self):
        self.assertTrue(np.isnan(locate.rank(np.nan, np.arange(5.0))))
        self.assertTrue(np.isnan(locate.rank(1.0, np.array([np.nan, np.nan]))))
        self.assertEqual(locate.rank(10.0, np.array([1.0, 2.0, np.nan])), 1.0)   # unscorable nulls don't count
        self.assertEqual(locate.rank(0.0, np.array([1.0, 2.0])), 0.0)
        self.assertEqual(locate.rank(1.5, np.array([1.0, 2.0])), 0.5)
        r = [locate.rank(s0, np.array([0.0, 1.0, 2.0, 3.0])) for s0 in (-1, 0.5, 1.5, 2.5, 4)]
        self.assertEqual(r, sorted(r))                                          # monotone in the truth

    def scene(self):
        sc = object.__new__(locate.Scene)
        sc.df = 5.86                                                            # Hz per bin, as at 48 kHz
        return sc

    def test_lines_of_picks_separate_lines_best_first(self):
        sc, F = self.scene(), locate.F0S
        prof = np.zeros(len(F))
        near = lambda f: int(np.argmin(np.abs(F - f)))
        for f, v in ((500, 3.0), (505, 2.9), (900, 2.0), (1500, 1.0)):            # 505 is inside 500's width
            prof[near(f)] = v
        picks = sc.line_picks(prof, 3)
        self.assertEqual([round(v, 1) for _, v in picks], [3.0, 2.0, 1.0])     # 505 Hz counted with 500
        width = (2 * locate.TOL_BINS + 1) * sc.df
        fs = [f for f, _ in picks]
        self.assertTrue(all(abs(a - b) >= width for i, a in enumerate(fs) for b in fs[i + 1:]))
        self.assertAlmostEqual(sc.lines_of(prof, 1), np.nanmax(prof))
        self.assertAlmostEqual(sc.lines_of(prof, 3), 6.0)
        # Each pick is no better than the one before (greedy, best first).
        vals = [v for _, v in sc.line_picks(np.random.default_rng(1).normal(size=len(F)), 8)]
        self.assertEqual(vals, sorted(vals, reverse=True))

    def test_lines_of_shifts_with_a_constant_and_is_nan_when_empty(self):
        sc = self.scene()
        prof = np.random.default_rng(2).normal(size=len(locate.F0S))
        for k in (1, 4):                       # a constant offset moves every curve alike: ranks hold
            self.assertAlmostEqual(sc.lines_of(prof + 0.7, k), sc.lines_of(prof, k) + 0.7 * k, places=9)
        self.assertTrue(np.isnan(sc.lines_of(np.full(len(locate.F0S), np.nan), 4)))

    def test_per_rest_is_the_scene_profile(self):
        from lab import fillmark, synth
        x = synth.room(30, seed=5)[: int(30 * synth.SR)]
        sc = locate.Scene(x, synth.SR, "test:inv:profile")
        j = np.flatnonzero(np.abs(sc.t - 15) <= 10)
        fac = fillmark.factor(sc.t[j], 15)
        np.testing.assert_array_equal(fillmark.per_rest(sc, j, fac), sc._profile(j, fac))
        self.assertTrue(np.isnan(fillmark.per_rest(sc, j[:5], fac[:5])).all())   # too few frames: nothing

    def test_corpus_halves_are_fixed_by_the_id_alone(self):
        ids = [f"N{k}XY_R{k % 70:02d}" for k in range(400)]
        halves = [zenodo.half(c) for c in ids]
        self.assertEqual(halves, [zenodo.half(c) for c in ids])               # same answer every time
        self.assertEqual(set(halves), {"tune", "holdout"})
        self.assertAlmostEqual(halves.count("tune") / len(ids), 0.5, delta=0.08)

    def test_u_is_nan_when_the_truth_cant_be_scored(self):
        t = np.arange(0, 50, 0.1707)
        ps = [{"case": f"c{k}", "t": t, "f": 300 * (1 + d / 2 - d / (1 + np.exp(-(t - 25) / 4)))} for k, d in enumerate((0.3, 0.1, 0.5))]
        x = np.random.default_rng(3).normal(0, 1, int(SR * 60))
        sc = locate.Scene(x, SR, "test:inv:u")
        u, n = zenodo.u(sc, ps[0], ps, offset=200.0)                          # the curve is past the audio's end
        self.assertTrue(np.isnan(u))
        self.assertEqual(n, 0)
        self.assertEqual(zenodo.ATTACKER_LINES, 4)                             # what THREAT_MODEL.md scores with


class BlankTest(unittest.TestCase):
    """lab/blank.py's pure parts (no session data)."""

    def test_expected_at_puts_the_closest_approach_where_asked(self):
        from lab import blank
        t = np.arange(0, 50, 0.1707)
        p = {"case": "c0", "t": t, "f": 300 * (1 + 0.15 - 0.3 / (1 + np.exp(-(t - 25) / 4)))}
        e = blank.expected_at(p, centre=70.0, duration=150.0)
        self.assertEqual(e["closest"], 70.0)
        ts, fs = np.array(e["times"]), np.array(e["factors"])
        steep = ts[np.argmin(np.gradient(fs, ts))]
        self.assertAlmostEqual(steep, 70.0, delta=0.5)                # the fall is at the centre
        self.assertTrue(ts[0] <= -59 and ts[-1] >= 209)                # covers the audio and the null shifts
        self.assertTrue(np.all((fs > 0.5) & (fs < 2)))                 # what the engine accepts


class ReviewFindings(unittest.TestCase):
    """Regressions for an independent review's findings (Nov 2026, at commit 8d2f75a)."""

    def test_f01_session_ids_cant_leave_the_sessions_folder(self):
        import json, tempfile, zipfile
        from pathlib import Path
        from lab import corpus
        with tempfile.TemporaryDirectory() as tmp:
            old = corpus.DATA
            corpus.DATA = Path(tmp) / "data"
            try:
                self.assertEqual(corpus.session_path("normal-session_1").name, "normal-session_1")
                for bad in ("../outside", "/tmp/arbitrary-target", "a/b", "", ".hidden", "x" * 200, None):
                    with self.assertRaises(ValueError, msg=repr(bad)):
                        corpus.session_path(bad)
                # A bundle whose meta.json names "../victim": refused, and nothing outside is touched.
                victim = Path(tmp) / "data" / "victim"
                victim.mkdir(parents=True)
                (victim / "keep.txt").write_text("x")
                bundle = Path(tmp) / "b.zip"
                with zipfile.ZipFile(bundle, "w") as z:
                    z.writestr("s/meta.json", json.dumps({"clip_id": "../victim"}))
                with self.assertRaises(ValueError):
                    corpus.ingest(bundle)
                self.assertTrue((victim / "keep.txt").exists())
                # A good id whose index fails: an existing session of that id is restored.
                existing = corpus.session_path("s1")
                existing.mkdir(parents=True)
                (existing / "keep.txt").write_text("old")
                with zipfile.ZipFile(bundle, "w") as z:
                    z.writestr("s/meta.json", json.dumps({"clip_id": "s1"}))     # no audio: index fails
                with self.assertRaises(Exception):
                    corpus.ingest(bundle)
                self.assertEqual((existing / "keep.txt").read_text(), "old")
            finally:
                corpus.DATA = old

    def test_f02_zero_spread_cant_make_an_infinite_score(self):
        S = np.zeros((4, 2, 3))
        S[:, :, 0] = [[1, 0], [2, 0], [0, 0], [0, 0]]   # scores; null mean 0 and spread 0 everywhere
        Z, floor = locate.zscores(S)
        self.assertTrue(np.all(floor > 0))
        self.assertTrue(np.all(np.isfinite(Z) | np.isnan(Z)))
        self.assertTrue(np.all(np.isfinite(locate.combine(Z))))
        self.assertLess(np.nanmax(np.abs(Z)), 1e4)
        bad = np.array([[np.inf, 1.0], [np.nan, -np.inf]])
        self.assertEqual(list(locate.combine(bad)), [1.0, 0.0])

    def test_f03_every_utc_half_hour_with_its_own_date(self):
        import datetime
        from lab import corpus
        ts = lambda s: datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp()
        got = [(d.strftime("%Y-%m-%d"), h) for d, h in corpus.half_hours(ts("2026-11-09T23:58:00"), ts("2026-11-10T00:03:00"))]
        self.assertEqual(got, [("2026-11-09", 47), ("2026-11-10", 0)])
        got = [h for _, h in corpus.half_hours(ts("2026-11-09T01:00:00"), ts("2026-11-09T04:00:00"))]
        self.assertEqual(got, [2, 3, 4, 5, 6, 7, 8])                          # no gaps
        got = [(d.strftime("%Y-%m-%d"), h) for d, h in corpus.half_hours(ts("2028-02-28T23:45:00"), ts("2028-02-29T00:10:00"))]
        self.assertEqual(got, [("2028-02-28", 47), ("2028-02-29", 0)])          # leap day
        self.assertEqual(len(corpus.half_hours(ts("2026-11-09T10:30:00"), ts("2026-11-09T10:30:00"))), 1)

    def test_f04_joint_null_keeps_aircraft_dependence(self):
        rng = np.random.default_rng(0)
        col = rng.normal(size=1100)
        Z = np.stack([col, col], 1)                     # two aircraft whose scores move together
        Z[0] = [2.3, 2.3]                               # the truth: combined 4.6
        def p(Z, joint):
            total = locate.combine(Z)
            real = locate.rank_bits(1 + np.sum(np.delete(total, 0) > total[0]), len(total))
            return np.mean(locate.null_bits(Z, 0, draws=20000, joint=joint) >= real)
        pj, pi = p(Z, True), p(Z, False)
        self.assertGreater(pj, 5 * pi)                  # independent draws make the truth look rarer
        Zi = np.stack([rng.normal(size=1100), rng.normal(size=1100)], 1)
        Zi[0] = [2.3, 2.3]                              # independent aircraft: the two agree
        self.assertAlmostEqual(p(Zi, True), p(Zi, False), delta=0.01)


class SyntheticEngine(unittest.TestCase):
    """lab/nulltest.py's engine: the public corpus's kind (a few unrelated lines, similar levels)."""

    def test_engine_lines(self):
        from lab import nulltest
        rng = np.random.default_rng(3)
        es = [nulltest.engine(rng) for _ in range(400)]
        n = np.array([len(e) for e in es])
        self.assertTrue(np.all((n >= 1) & (n <= 6)))
        self.assertAlmostEqual(np.mean(n - 1), 2.0, delta=0.3)          # Poisson(2), capped at 5
        for e in es:
            f = np.array([a for a, _ in e])
            self.assertEqual(e[0][1], 1.0)                              # the main line first
            r = f[:, None] / f[None, :]
            self.assertTrue(np.all((abs(r - 1) > 0.05) | np.eye(len(f), dtype=bool)))   # 5 % apart
            self.assertTrue(all(10 ** (-6 / 20) - 1e-9 <= a <= 10 ** (3 / 20) + 1e-9 for _, a in e[1:]))
        h = nulltest.engine(rng, "harmonic")
        self.assertEqual([round(f / h[0][0], 6) for f, _ in h], [1.0, 2.0, 3.0])
        # The same seed gives the same engine (runs pair across variants by seed).
        self.assertEqual(nulltest.engine(np.random.default_rng(9)), nulltest.engine(np.random.default_rng(9)))


class Holdout(unittest.TestCase):
    def test_scoring_refuses_the_holdout_unless_asked(self):
        from lab.__main__ import main
        sid = "20990101T000000Z_" + corpus.HOLDOUT[0]
        for cmd in ("locate", "attack", "trackfill", "cloak"):
            with self.assertRaises(SystemExit) as e:
                main([cmd, sid])
            self.assertIn("holdout", str(e.exception))
        self.assertTrue(corpus.is_holdout(sid))
        self.assertFalse(corpus.is_holdout("20990101T000000Z_abcdef"))


class ShapeTest(unittest.TestCase):
    """The flyby fit, on curves made independently of it (lab.synth's own propagation)."""

    def test_recovers_a_propagated_pass(self):
        from lab import synth
        truth, _ = synth.fan_path()                   # 1,234 Hz, 141 m/s, 2 km
        dt = 0.0427
        fit = detect.shape_test(truth(22 + np.arange(234) * dt), 10.0, dt=dt)
        self.assertTrue(fit["ok"])
        self.assertAlmostEqual(fit["f0"], 1234, delta=2)
        self.assertAlmostEqual(fit["speed"], 141, delta=2)
        self.assertAlmostEqual(fit["distance"], 2000, delta=40)

    def test_rejects_a_scale_and_a_siren(self):
        dt, t = 0.0427, np.arange(234) * 0.0427
        scale = 1800 * 2 ** (-np.floor(t / 0.5) / 24)          # a step every half second
        siren = 1200 + 400 * np.sin(2 * np.pi * t / 4)
        self.assertFalse(detect.shape_test(scale, 10.0, dt=dt)["ok"])
        self.assertFalse(detect.shape_test(siren, 10.0, dt=dt)["ok"])


class BlindSearch(unittest.TestCase):
    def test_follows_a_faint_pass(self):
        from lab import synth
        x, truth = synth.fan(20)
        p = detect.Params()
        f, t, L = detect.whiten(x, synth.SR, p)
        wins = [w for w in detect.search(f, t, L - L.mean(), p) if np.isfinite(w.score)]
        best = max(wins, key=lambda w: w.score)
        tt = best.start + np.arange(len(best.path)) * (t[1] - t[0])
        self.assertLess(np.median(np.abs(best.path - truth(tt)) / truth(tt)), 0.01)
        self.assertTrue(detect.shape_test(best.path, p.win_s, dt=float(t[1] - t[0]))["ok"])


class KnownPath(unittest.TestCase):
    def test_finds_a_faint_tone_along_its_curve(self):
        z, rest, off = known(passing_tone())
        self.assertGreater(z, 5)
        # Rest frequency and timing trade off along the curve: a few percent and seconds.
        self.assertAlmostEqual(rest, 900, delta=30)
        self.assertLessEqual(abs(off), 3.0)

    def test_the_fast_search_agrees_with_a_lookup_per_rest(self):
        """The log-axis search (all rests at once, timings shared) against the plain one: for
        each rest, the excess looked up along its curve, frame by frame."""
        x = passing_tone(snr_db_hz=12)
        f, tt, L = detect.whiten(x, SR, P_KNOWN)
        A = detect._tolerant(L - L.mean(), 2)
        rests = 500 * detect.RATIO ** np.arange(0, 550, 25)
        for tau in (0.0, 1.5, -22.5):
            fast = detect._known_path_search(f, tt, L - L.mean(), factor, (500, 1500), (5, 55), [tau])[tau]
            j = np.flatnonzero((tt >= 5) & (tt <= 55))
            fac = factor(tt[j] - tau)
            slow = []
            for r in rests:
                k = np.round((r * fac - f[0]) / (f[1] - f[0])).astype(int)
                slow.append(A[k, j].mean() if k.min() >= 0 and k.max() < len(f) else -np.inf)
            # The fast one searches every 0.2 % step, so its best is at least the coarse grid's best,
            # and not above the best within a step of it.
            self.assertGreaterEqual(fast[0] + 1e-4, max(slow))
            self.assertLess(fast[0] - max(slow), 0.5)


class EnvelopeAttacker(unittest.TestCase):
    """The loudness-envelope attacker (lab/envelope.py): a room whose level follows a flyby's
    predicted level scores; what doesn't follow it, or can't be told from a drift, doesn't."""

    SR, SECS, C = 8_000, 120, 343.0
    # A smaller search than the lab's (one band, ±2 s, 16 wrong times) keeps these fast; the
    # statistic and its guards are the same.
    FAST = dict(offsets=np.arange(-2, 2.01, 1.0), shifts=tuple(s * d for d in np.arange(20.0, 60.1, 5.5) for s in (-1, 1)), min_nulls=12)
    BAND = ((40.0, 1500.0),)

    @staticmethod
    def flyby(side=1_500.0, up=1_200.0, speed=150.0, closest=40.0):
        te = np.arange(-200, 300, 0.1)
        q = np.stack([speed * (te - closest), np.full_like(te, side), np.full_like(te, up)], 1)
        return te, q, np.gradient(q, te, axis=0)

    @classmethod
    def room(cls, seed=4):
        return np.random.default_rng(seed).normal(0, 1, cls.SR * cls.SECS)

    @classmethod
    def with_plane(cls, room, track, over_db=6.0, seed=5, shift=0.0, invert=False):
        """The room plus broadband noise at the track's predicted level, `over_db` above the room
        at its loudest (moved `shift` s; louder when farther if `invert`)."""
        from lab import envelope
        heard, pred = envelope.predicted_level(track[0], track[1], cls.C, cls.BAND[0])
        t = np.arange(len(room)) / cls.SR
        lv = np.interp(t - shift, heard, pred) - pred.max()
        if invert:
            lv = -lv + lv.min()
        return room + np.random.default_rng(seed).normal(0, 1, len(room)) * 10 ** ((lv + over_db) / 20)

    @classmethod
    def score(cls, x, track, **kw):
        from lab import envelope
        return envelope.envelope_z(*envelope.band_levels(x, cls.SR, bands=cls.BAND), track, cls.C, **{**cls.FAST, **kw})

    def test_a_plane_in_the_room_scores_and_the_room_alone_doesnt(self):
        tr = self.flyby()
        for seed in (1, 2, 3):
            room = self.room(seed)
            z, r2, _, _ = self.score(self.with_plane(room, tr, seed=seed + 10), tr)
            self.assertGreater(z, 5, f"seed {seed}")
            self.assertGreater(r2, 0.8, f"seed {seed}")
            self.assertLess(self.score(room, tr)[0], 2.5, f"seed {seed}")

    def test_a_gain_changes_nothing(self):
        tr = self.flyby()
        x = self.with_plane(self.room(), tr)
        a, b = self.score(x, tr), self.score(100 * x, tr)
        self.assertAlmostEqual(a[0], b[0], places=6)
        self.assertAlmostEqual(a[1], b[1], places=6)

    def test_taps_and_clicks_dont_count(self):
        """The quiet percentile within each second ignores short loud things."""
        tr = self.flyby()
        room = self.room()
        tapped = room.copy()
        rng = np.random.default_rng(9)
        for at in rng.uniform(5, self.SECS - 5, 30):
            i = int(at * self.SR)
            tapped[i:i + 80] += 200 * rng.normal(0, 1, 80)         # 10 ms, 46 dB above the room
        self.assertLess(self.score(tapped, tr)[0], 2.5)
        x = self.with_plane(room, tr)
        self.assertAlmostEqual(self.score(x, tr)[0], self.score(x + (tapped - room), tr)[0], delta=1.0)

    def test_the_wrong_time_or_the_wrong_way_round_doesnt_score(self):
        tr = self.flyby()
        room = self.room()
        self.assertLess(self.score(self.with_plane(room, tr, shift=45), tr)[0], 2.5)
        self.assertLess(self.score(self.with_plane(room, tr, invert=True), tr)[0], 2.5)

    def test_a_drifting_room_is_not_a_plane(self):
        """A room getting steadily louder (+9.5 dB over the clip) against a near and a far
        aircraft: every wrong time fits a drift as well as the right one does."""
        drifting = self.room() * np.linspace(1, 3, self.SR * self.SECS)
        for tr in (self.flyby(), self.flyby(side=30_000.0)):
            z = self.score(drifting, tr)[0]
            self.assertTrue(np.isnan(z) or z < 2.5, z)

    def test_a_prediction_that_barely_moves_gives_no_verdict(self):
        """A prediction that changes by under 1.5 dB over the clip (an aircraft hovering 3 km away):
        no score at all, not a guess."""
        from lab import envelope
        flat = self.flyby(side=3_000.0, speed=2.0)
        heard, pred = envelope.predicted_level(flat[0], flat[1], self.C, self.BAND[0])
        inside = (heard > 2.5) & (heard < self.SECS - 2.5)
        self.assertLess(np.ptp(pred[inside]), 1.5)
        z, r2, band, _ = self.score(self.room() * np.linspace(1, 3, self.SR * self.SECS), flat)
        self.assertTrue(np.isnan(z) and np.isnan(r2) and band is None)

    def test_predicted_level_survives_glitches(self):
        from lab import envelope
        te, q, _ = self.flyby()
        q = q.copy()
        q[1_000] = [0.0, 0.0, 0.0]                  # a position at the listener: r floored, not −∞
        q[2_000:2_005] += 400_000.0                  # a jump that would send heard time backwards
        heard, lv = envelope.predicted_level(te, q, self.C, self.BAND[0])
        self.assertTrue(np.all(np.diff(heard) > 0))
        self.assertTrue(np.all(np.isfinite(lv)))

    def test_bands_past_nyquist_are_left_out(self):
        from lab import envelope
        _, lv = envelope.band_levels(self.room()[: 4_000 * 30], 4_000, bands=((40.0, 1500.0), (1500.0, 4000.0)))
        self.assertEqual(list(lv), [(40.0, 1500.0)])

    def test_the_fit_holds_the_size_of_the_change(self):
        """A 1 dB drift shaped like a predicted 10 dB fade fits worse than the fade itself, unlike
        a correlation (the first version), which scores both 1.0."""
        from lab import envelope
        pred = np.linspace(0, -10, 60)
        self.assertGreater(envelope.fit_r2(pred + 3, pred), 0.99)
        self.assertLess(envelope.fit_r2(pred / 10 + 3, pred), envelope.fit_r2(pred + 3, pred))
        self.assertTrue(np.isnan(envelope.fit_r2(np.full(60, 2.0), pred)))

    def test_deterministic(self):
        tr = self.flyby()
        x = self.with_plane(self.room(), tr)
        self.assertEqual(self.score(x, tr), self.score(x, tr))


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

    def test_curves_handed_to_the_engine_are_usable(self):
        from lab.__main__ import clean_curve
        heard = np.array([0.0, 1.0, 1.0004, 0.5, 2.0, 3.0, 4.0])          # a rounding tie, a jump back
        fac = np.array([1.2, 1.1, 1.1, 1.0, 2.6, 0.9, np.nan])            # a glitch above 2, a NaN
        c = clean_curve(heard, fac, 1.5)
        self.assertEqual(c["times"], [0.0, 1.0, 3.0])
        self.assertTrue(all(0.5 < f < 2 for f in c["factors"]))
        self.assertEqual(c["closest"], 1.5)

    def test_pressure_altitude(self):
        self.assertAlmostEqual(corpus.pressure_altitude_m(101.325), 0, delta=0.01)
        self.assertAlmostEqual(corpus.pressure_altitude_m(89.876), 1_000, delta=2)    # ICAO table
        meta = {"pressure_at_start": {"pressure_kpa": 101.325}, "location_at_start": {"alt_m": 50}}
        self.assertEqual(corpus.vertical_reference(meta)[1], "pressure")
        self.assertEqual(corpus.vertical_reference({"location_at_start": {"alt_m": 50}}), (50, "gps"))

    def test_only_positions_pass_the_plausibility_check(self):
        self.assertTrue(corpus._plausible(37.0, -122.0, 3_000))
        self.assertTrue(corpus._plausible(37.0, -122.0, None))
        self.assertFalse(corpus._plausible(1_290.0, -122.0, 3_000))     # not a position row
        self.assertFalse(corpus._plausible(37.0, -122.0, 321_250))


if __name__ == "__main__":
    unittest.main()


class SyntheticPasses(unittest.TestCase):
    """The benchmark's generator (lab/passes.py)."""

    def test_draws_stay_in_bounds(self):
        from lab import passes
        rng = np.random.default_rng(0)
        for _ in range(200):
            p = passes.draw(rng, 60)
            self.assertTrue(500 <= p.distance <= 6_000)
            self.assertTrue(0.15 * 60 <= p.t_close <= 0.85 * 60)
            swing = (1 / (1 + p.speed / passes.C), 1 / (1 - p.speed / passes.C))
            for f, _, _ in p.tones:                         # every tone stays in the band all pass
                self.assertGreaterEqual(f * swing[0], passes.BAND[0])
                self.assertLessEqual(f * swing[1], passes.BAND[1])

    def test_curve_falls_through_the_rest_frequency_at_closest_approach(self):
        from lab import passes
        p = passes.Pass(speed=150, altitude=1_000, offset=500, t_close=30, tones=[(1_000.0, 0.0, 0.0)])
        t = np.arange(0, 60, 0.05)
        factor = passes.geometry(p, t)[0]
        self.assertTrue(np.all(np.diff(factor) < 1e-12))
        self.assertAlmostEqual(float(np.interp(30, t, factor)), 1.0, delta=1e-3)

    def test_strength_is_what_was_asked_for(self):
        from lab import passes
        from scipy.signal import welch
        sr, rng = 16_000, np.random.default_rng(3)
        p = passes.Pass(speed=60, altitude=3_000, offset=0, t_close=30, tones=[(1_000.0, 0.0, 0.0)],
                        wander=0.0, scintillation_db=0.0, reflection=0.0)
        bg = rng.normal(0, 1, 60 * sr)
        x, _ = passes.mix(bg, sr, p, 20.0, rng)
        f, P = welch(x[28 * sr: 32 * sr], sr, nperseg=sr)              # 1 Hz bins around closest
        tone = P[(f > 990) & (f < 1_010)].sum()                        # power, summed over the line
        noise = np.median(P[(f > 900) & (f < 1_100)])                   # per Hz
        self.assertAlmostEqual(10 * np.log10(tone / noise), 20.0, delta=1.5)


class LearnedDetectorPlumbing(unittest.TestCase):
    """lab/ml.py's data path (no training: jax isn't needed for these)."""

    def test_a_tone_lands_on_its_log_bin_and_is_labelled_there(self):
        from lab import ml, passes
        rng = np.random.default_rng(1)
        p = passes.Pass(speed=120, altitude=1_500, offset=0, t_close=15, tones=[(900.0, 0.0, 0.0)],
                        wander=0.0, scintillation_db=0.0, reflection=0.0)
        x, truth = passes.mix(rng.normal(0, 1, 30 * ml.SR), ml.SR, p, 20.0, rng)
        F, t = ml.features(x, ml.SR)
        self.assertEqual(F.shape[0], ml.NBINS)
        y, w = ml.labels(truth, 20.0, t)
        j = int(np.argmin(np.abs(t - 15)))                      # at closest approach
        b = int(np.argmax(y[:, j]))
        self.assertEqual(y[b, j], 1)
        self.assertLess(abs(ml.CENTERS[b] / 900 - 1), 0.03)
        self.assertGreater(F[b, j], 6)                           # the tone stands out in the input
        self.assertEqual(w[b - 1, j], 0)                         # neighbours don't count

    def test_windows_group_into_passes_of_two_or_more(self):
        from lab import ml
        wins = [(10, 20, 900, 1000, 0.9), (12.5, 22.5, 880, 990, 0.8), (40, 50, 500, 520, 0.95), (60, 70, 300, 320, 0.1)]
        self.assertEqual(ml.group(wins, 0.5), [(10, 22.5, 880, 1000, 0.9)])
        self.assertEqual(len(ml.group(wins, 0.5, min_windows=1)), 2)
