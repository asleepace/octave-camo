import XCTest
@testable import OctaveCamoKit
import OctaveCamoIO
import Foundation
/// A diagnostic, skipped unless asked for: the attacker's excess along curves before and after a
/// fill there. FILLPROBE=<json of {case, wav, wrong, true}> fills along each clip's wrong-place curve
/// at rests 150 Hz–3 kHz (FILLPROBE_LEVEL picks LineFill.Level, FILLPROBE_OUT saves the audio);
/// FILLPROBE_SYNTH=1 runs the white- and pink-noise version.
final class FillProbeTests: XCTestCase {
    func along(_ p: TrackFill.Prepared, _ pass: ExpectedPass, rest: Double, half: Double, useMax: Bool) -> Double {
        var s = 0.0, n = 0
        for m in 0..<p.g.frames where abs(p.g.time(m) - pass.center) <= half {
            guard let f = pass.factor(at: p.g.time(m)) else { continue }
            let k = Int((rest * f / p.g.binHz).rounded()) - p.g.kLo
            guard k >= 0, k < p.g.bins else { continue }
            s += Double(useMax ? p.am[m * p.g.bins + k] : p.a[m * p.g.bins + k]); n += 1
        }
        return s / Double(max(n, 1))
    }
    struct Item: Decodable { let `case`: String; let wav: String; let wrong: ExpectedPass; let `true`: ExpectedPass }
    func testCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["FILLPROBE"] else { throw XCTSkip("no FILLPROBE") }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var all: [Double] = [], allCtl: [Double] = [], lowAll: [Double] = [], befores: [Double] = [], afters: [Double] = []
        for it in items {
            let audio = try WAV.read(from: it.wav), x = audio.mono, rate = audio.sampleRate
            for (label, pass) in [("wrong", it.wrong)] {
                var stage = TrackFill(); stage.expected = [pass]; stage.seed = 9
                var y = x, rng = SeededRNG(seed: 11)
                var fill = LineFill(); fill.marginHz = stage.marginHz; fill.relativeMargin = stage.relativeMargin
                if let l = ProcessInfo.processInfo.environment["FILLPROBE_LEVEL"].flatMap(LineFill.Level.init(rawValue:)) { fill.level = l }
                let rests = stride(from: 150.0, through: 3000, by: 97).map { $0 }
                for r in rests {
                    let tone = TrackFill.Tone(pass: 0, rest: r, offset: 0, z: 0, effect: 0)
                    if let line = stage.track(tone, sampleRate: rate, count: y.count) { _ = fill.fill(&y, line, sampleRate: rate, rng: &rng) }
                }
                if let dir = ProcessInfo.processInfo.environment["FILLPROBE_OUT"] {
                    try WAV.write(Audio(sampleRate: rate, channels: [y]), to: "\(dir)/\(it.case).wav")
                }
                guard let px = stage.prepare(x, sampleRate: rate), let py = stage.prepare(y, sampleRate: rate) else { continue }
                var d: [Double] = [], c: [Double] = []
                for r in rests {
                    befores.append(along(px, pass, rest: r, half: stage.halfWindow, useMax: true))
                    afters.append(along(py, pass, rest: r, half: stage.halfWindow, useMax: true))
                    d.append(along(py, pass, rest: r, half: stage.halfWindow, useMax: true) - along(px, pass, rest: r, half: stage.halfWindow, useMax: true))
                    c.append(along(py, pass, rest: r + 48, half: stage.halfWindow, useMax: true) - along(px, pass, rest: r + 48, half: stage.halfWindow, useMax: true))
                }
                all += d; allCtl += c; lowAll += Array(d.prefix(5))
                let m = d.reduce(0, +) / Double(d.count), mc = c.reduce(0, +) / Double(c.count)
                let top = d.enumerated().max { $0.1 < $1.1 }!
                print("PROBE \(it.case) \(label) rate \(rate): filled \(String(format: "%+.3f", m)) control \(String(format: "%+.3f", mc)) max \(String(format: "%+.2f", top.1)) at \(Int(rests[top.0])) Hz; by rest: \(d.map { String(format: "%+.2f", $0) }.joined(separator: " "))")
            }
        }
        let m = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        let q = { (v: [Double], p: Double) -> Double in let s = v.sorted(); return s[min(s.count - 1, Int(p * Double(s.count)))] }
        let hi = Array(zip(befores, afters).enumerated().filter { $0.offset % 30 >= 5 }.map { $0.element })   // rests ≥ 600 Hz
        for (name, v) in [("before", hi.map { $0.0 }), ("after", hi.map { $0.1 })] {
            print("PROBE QUANTILES ≥600 Hz \(name): 50% \(String(format: "%+.3f", q(v, 0.5))) 90% \(String(format: "%+.3f", q(v, 0.9))) 97% \(String(format: "%+.3f", q(v, 0.97))) 99% \(String(format: "%+.3f", q(v, 0.99))) max \(String(format: "%+.3f", v.max()!))")
        }
        print("PROBE ALL filled \(String(format: "%+.3f", m(all))) control \(String(format: "%+.3f", m(allCtl))) below 600 Hz \(String(format: "%+.3f", m(lowAll))) n \(all.count)")
    }
    func testProbe() throws {
        guard ProcessInfo.processInfo.environment["FILLPROBE_SYNTH"] != nil else { throw XCTSkip("no FILLPROBE_SYNTH") }
        for rate in [16_000, 48_000] {
            for kind in ["white", "pink"] {
                var x = DetectionScenes.white(rate * 60, seed: 3)
                if kind == "pink" {   // a crude pink: integrate white with leak
                    var acc = 0.0; for i in x.indices { acc = 0.995 * acc + x[i]; x[i] = acc * 0.1 + x[i] * 0.2 }
                }
                var stage = TrackFillTests.stage([TrackFillTests.expected()])
                stage.seed = 9
                let pass = stage.expected[0]
                var y = x, rng = SeededRNG(seed: 11)
                var fill = LineFill(); fill.marginHz = stage.marginHz; fill.relativeMargin = stage.relativeMargin
                let rests = stride(from: 300.0, through: 3000, by: 97).map { $0 }
                for r in rests {
                    let tone = TrackFill.Tone(pass: 0, rest: r, offset: 0, z: 0, effect: 0)
                    if let line = stage.track(tone, sampleRate: rate, count: y.count) { _ = fill.fill(&y, line, sampleRate: rate, rng: &rng) }
                }
                let px = stage.prepare(x, sampleRate: rate)!, py = stage.prepare(y, sampleRate: rate)!
                var dMax: [Double] = [], dRaw: [Double] = [], ctl: [Double] = []
                for r in rests {
                    dMax.append(along(py, pass, rest: r, half: stage.halfWindow, useMax: true) - along(px, pass, rest: r, half: stage.halfWindow, useMax: true))
                    dRaw.append(along(py, pass, rest: r, half: stage.halfWindow, useMax: false) - along(px, pass, rest: r, half: stage.halfWindow, useMax: false))
                    let rc = r + 48 // between filled rests
                    ctl.append(along(py, pass, rest: rc, half: stage.halfWindow, useMax: true) - along(px, pass, rest: rc, half: stage.halfWindow, useMax: true))
                }
                let m = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
                let sd = { (v: [Double]) -> Double in let mu = m(v); return (v.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(v.count)).squareRoot() / Double(v.count).squareRoot() }
                print("PROBE \(rate) \(kind): along filled curve, excess change (best of ±2 bins) \(String(format: "%+.3f ± %.3f", m(dMax), sd(dMax)))  raw \(String(format: "%+.3f ± %.3f", m(dRaw), sd(dRaw)))  control (between) \(String(format: "%+.3f ± %.3f", m(ctl), sd(ctl)))  n \(rests.count)")
            }
        }
    }
}
