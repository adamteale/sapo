import Foundation
import AppKit

// CLI entry: any argument switches to tool mode; no arguments launches the GUI.
if let code = runCLI() {
    exit(code)
}

StemsApp.main()

func runCLI() -> Int32? {
    let args = CommandLine.arguments
    guard args.count > 1 else { return nil }
    let command = args[1]

    switch command {
    case "--list-taps":
        let registry = SourceRegistry()
        let apps = registry.currentAppSources()
        let mics = registry.currentMicSources()
        guard !apps.isEmpty || !mics.isEmpty else {
            print("no sources found (is any app playing audio?)")
            return 0
        }
        print("APPLICATIONS")
        for a in apps { print("  \(a.id)\t\(a.name)") }
        print("MICROPHONES")
        for m in mics { print("  \(m.id)\t\(m.name)") }
        return 0
    default:
        FileHandle.standardError.write("unknown command \(command)\n".data(using: .utf8)!)
        return 64
    }
}
