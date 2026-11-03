/// A usage error: printed with the help text, exit code 2.
struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `--key value` options, `--flag` switches and positionals. Unknown options are errors.
struct Arguments {
    private var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init<S: Sequence>(_ argv: S, options allowedOptions: Set<String>, flags allowedFlags: Set<String>) throws
    where S.Element == String {
        var it = argv.makeIterator()
        while let arg = it.next() {
            guard arg.hasPrefix("--") else { positionals.append(arg); continue }
            let key = String(arg.dropFirst(2))
            if allowedFlags.contains(key) {
                flags.insert(key)
            } else if allowedOptions.contains(key) {
                guard let value = it.next() else { throw UsageError("--\(key) needs a value") }
                options[key] = value
            } else {
                throw UsageError("unknown option --\(key)")
            }
        }
    }

    func positional(at index: Int, named name: String) throws -> String {
        guard index < positionals.count else { throw UsageError("missing \(name)") }
        return positionals[index]
    }

    func flag(_ key: String) -> Bool { flags.contains(key) }

    func string(_ key: String) -> String? { options[key] }

    func value<T: LosslessStringConvertible>(_ key: String, default fallback: T) throws -> T {
        guard let raw = options[key] else { return fallback }
        guard let value = T(raw) else { throw UsageError("invalid value for --\(key): \(raw)") }
        return value
    }
}
