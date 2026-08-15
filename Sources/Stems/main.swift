import Foundation

// CLI entry: any argument switches to tool mode; no arguments launches the GUI.
// Tasks 4+7 add subcommands by extending runCLI().
if let code = runCLI() {
    exit(code)
}

StemsApp.main()

// Keep in main.swift until Task 4 introduces real subcommands.
func runCLI() -> Int32? {
    let args = CommandLine.arguments
    guard args.count > 1 else { return nil }
    FileHandle.standardError.write("unknown arguments: \(args.dropFirst())\n".data(using: .utf8)!)
    return 64 // EX_USAGE
}
