import Foundation

/// Splits the low end into bands (raised-cosine crossovers that sum to 1) and gives each band
/// its own slow random frequency drift. Harmonics of one aircraft land in different bands, so
/// they stop moving together and the drift can't be estimated from one and divided out.
///
/// Implementation: one full-size FFT of the clip. Each band's analytic signal only contains
/// content below a few hundred Hz, so the drift is applied at a decimated rate with small FFTs,
/// and every band's result is summed back into the one spectrum. One full-size inverse FFT
/// then reconstructs the output (two big FFTs total instead of one per band).
public struct BandWobble: ScrubStage {
    var step: ScrubStep { .wobble }

    /// Upper edge of the wobbled range, Hz. 600 is the default: at 400, residual fragments of
    /// an aircraft's upper harmonics can still yield the true distance. 400 is gentler on voices.
    public var top = 600.0
    /// Peak drift as a fraction of each band's center frequency.
    public var depth = 0.015
    /// Crossover width as a fraction of each edge frequency.
    public var crossover = 0.15
    /// Drift is a sum of `components` sines with periods drawn from this range, s.
    public var periodRange: ClosedRange<Double> = 1...4
    public var components = 3
    public var seed: UInt64 = .random(in: 1...UInt64.max)

    /// Band edges below `top`; `top` closes the last band.
    public static let baseEdges: [Double] = [30, 55, 80, 110, 150, 200, 270, 400]

    public init() {}

    var edges: [Double] { Self.baseEdges.filter { $0 < top } + [top] }

    public func process(_ x: [Double], sampleRate: Int) -> (output: [Double], summary: String) {
        let edges = self.edges
        guard edges.count >= 2, !x.isEmpty else { return (x, "wobble: skipped (no bands below \(Int(top)) Hz)") }

        let n = x.count, sr = Double(sampleRate)
        // ≥ 0.25 s of padding gives the drift phase room to return smoothly to its start value
        // before the FFT's circular seam (a jump there would splatter into the clip's start).
        let bigSize = DSP.nextPowerOfTwo(atLeast: n + sampleRate / 4)
        let binHz = sr / Double(bigSize)
        let maxBandHz = edges[edges.count - 1] * (1 + crossover)
        // Decimated rate ≥ 4× the highest band frequency; analytic signals need no negative band.
        let smallSize = min(DSP.nextPowerOfTwo(atLeast: Int((Double(bigSize) * 4 * maxBandHz / sr).rounded(.up))), bigSize)
        let activeBins = min(Int((maxBandHz / binHz).rounded(.up)) + 2, smallSize / 2)

        // Spectrum of the whole clip.
        var specRe = [Double](repeating: 0, count: bigSize)
        var specIm = [Double](repeating: 0, count: bigSize)
        for i in 0..<n { specRe[i] = x[i] }
        let big = FFT(size: bigSize)
        big.forward(&specRe, &specIm)
        let bandRe = Array(specRe[0..<activeBins]), bandIm = Array(specIm[0..<activeBins])

        // Remove the wobbled range from both halves; everything else passes through untouched.
        for k in 0..<activeBins {
            let f = Double(k) * binHz
            let keep = 1 - (ramp(f, edges[0]) - ramp(f, edges[edges.count - 1]))
            specRe[k] *= keep; specIm[k] *= keep
            if k > 0 { specRe[bigSize - k] *= keep; specIm[bigSize - k] *= keep }
        }

        // Each band: analytic signal at the decimated rate, apply drift, add back (positive bins only).
        let small = FFT(size: smallSize)
        let dt = Double(bigSize) / (Double(smallSize) * sr)
        let covered = min(Int((Double(n) / (Double(bigSize) / Double(smallSize))).rounded(.up)), smallSize)
        var rng = SeededRNG(seed: seed)
        var zRe = [Double](repeating: 0, count: smallSize)
        var zIm = [Double](repeating: 0, count: smallSize)

        for b in 0..<(edges.count - 1) {
            let lo = edges[b], hi = edges[b + 1]
            for i in 0..<smallSize { zRe[i] = 0; zIm[i] = 0 }
            for k in 1..<activeBins {
                let gain = 2 * (ramp(Double(k) * binHz, lo) - ramp(Double(k) * binHz, hi))
                zRe[k] = bandRe[k] * gain
                zIm[k] = bandIm[k] * gain
            }
            small.inverse(&zRe, &zIm)

            let psi = driftPhase(count: smallSize, dt: dt, centerHz: (lo * hi).squareRoot(), covered: covered, rng: &rng)
            for j in 0..<smallSize {
                let c = cos(psi[j]), s = sin(psi[j])
                (zRe[j], zIm[j]) = (zRe[j] * c - zIm[j] * s, zRe[j] * s + zIm[j] * c)
            }
            small.forward(&zRe, &zIm)
            for k in 0..<smallSize { specRe[k] += zRe[k]; specIm[k] += zIm[k] }
        }

        big.inverse(&specRe, &specIm)
        let summary = "wobble: \(edges.count - 1) bands up to \(Int(top)) Hz, ±\(depth * 100)%"
        return (Array(specRe[0..<n]), summary)
    }

    /// 0 below the edge, 1 above, raised cosine across ±crossover·edge.
    func ramp(_ f: Double, _ edge: Double) -> Double {
        let w = crossover * edge
        let u = DSP.clamp((f - (edge - w)) / (2 * w), 0, 1)
        return 0.5 - 0.5 * cos(Double.pi * u)
    }

    /// Integrated random drift for one band. Past `covered` (the padding) the phase blends
    /// smoothly back to its starting value so the circular transform sees no discontinuity.
    func driftPhase(count: Int, dt: Double, centerHz: Double, covered: Int, rng: inout SeededRNG) -> [Double] {
        let sines = (0..<components).map { _ in (period: rng.uniform(periodRange), offset: rng.uniform(0...(2 * Double.pi))) }
        let scale = depth / Double(max(components, 1)) * centerHz
        let driftHz = (0..<count).map { j -> Double in
            let t = Double(j) * dt
            return scale * sines.reduce(0) { $0 + sin(2 * Double.pi * t / $1.period + $1.offset) }
        }
        var psi = DSP.cumulativePhase(driftHz, dt: dt)
        let padding = count - covered
        if covered > 0, padding > 0 {
            let end = psi[covered - 1], startValue = psi[0]
            for i in 1...padding {
                let w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(padding + 1))
                psi[covered - 1 + i] = end + w * (startValue - end)
            }
        }
        return psi
    }
}
