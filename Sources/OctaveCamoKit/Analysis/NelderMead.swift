/// Derivative-free simplex minimizer (standard reflect / expand / contract / shrink).
struct NelderMead {
    var iterations = 600

    func minimize(_ f: ([Double]) -> Double, start: [Double], scale: [Double]) -> (point: [Double], value: Double) {
        let n = start.count
        precondition(scale.count == n, "scale must match start")

        // Moves from `from` toward `to` by fraction s (negative s reflects away).
        func along(_ from: [Double], _ to: [Double], _ s: Double) -> [Double] {
            (0..<n).map { from[$0] + s * (to[$0] - from[$0]) }
        }

        var points = [start] + (0..<n).map { i -> [Double] in
            var p = start
            p[i] += scale[i]
            return p
        }
        var values = points.map(f)

        for _ in 0..<iterations {
            let order = values.indices.sorted { values[$0] < values[$1] }
            points = order.map { points[$0] }
            values = order.map { values[$0] }

            var centroid = [Double](repeating: 0, count: n)
            for p in points.dropLast() {
                for j in 0..<n { centroid[j] += p[j] / Double(n) }
            }
            let worst = points[n]

            let reflected = along(centroid, worst, -1)
            let fr = f(reflected)
            if fr < values[0] {
                let expanded = along(centroid, worst, -2)
                let fe = f(expanded)
                (points[n], values[n]) = fe < fr ? (expanded, fe) : (reflected, fr)
            } else if fr < values[n - 1] {
                (points[n], values[n]) = (reflected, fr)
            } else {
                let contracted = along(centroid, worst, 0.5)
                let fc = f(contracted)
                if fc < values[n] {
                    (points[n], values[n]) = (contracted, fc)
                } else {
                    for i in 1...n {
                        points[i] = along(points[0], points[i], 0.5)
                        values[i] = f(points[i])
                    }
                }
            }
        }
        let best = values.indices.min(by: { values[$0] < values[$1] }) ?? 0
        return (points[best], values[best])
    }
}
