import Foundation
import OctaveCamoKit

let argv = Array(CommandLine.arguments.dropFirst())

if argv.first == "--version" {
    print("octave-camo \(OctaveCamo.version)")
    exit(0)
}

guard let name = argv.first, !["-h", "--help", "help"].contains(name) else {
    print(usage)
    exit(0)
}

do {
    guard let command = commands.first(where: { $0.name == name }) else {
        throw UsageError("unknown command '\(name)'")
    }
    let args = try Arguments(argv.dropFirst(), options: command.options, flags: command.flags)
    try command.run(args)
} catch let error as UsageError {
    Output.stderr("error: \(error)\n\n\(usage)")
    exit(2)
} catch {
    Output.stderr("error: \(error)")
    exit(1)
}
