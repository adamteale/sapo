import Foundation
import CoreAudio

func flagValue(_ flag: String, in args: [String], default def: String) -> String {
    guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) else { return def }
    return args[idx + 1]
}

enum RecordCLI {
    static func recordApp(bundleID: String, seconds: Double, outDir: URL) -> Int32 {
        let registry = SourceRegistry()
        let objectIDs = registry.processObjectIDs(for:
            SourceDescriptor(id: bundleID, kind: .application, name: bundleID,
                             bundleIdentifier: bundleID, deviceUID: nil))
        guard !objectIDs.isEmpty else {
            FileHandle.standardError.write("no audio processes for \(bundleID) — is it playing sound?\n".data(using: .utf8)!)
            return 1
        }
        do {
            var tap = try ProcessTapSession.create(processObjectIDs: objectIDs, name: bundleID)
            defer { tap.dispose() }
            let stem = outDir.appendingPathComponent("stem-\(bundleID.replacingOccurrences(of: "/", with: "-")).caf")
            let chain = try CaptureChain.make(deviceID: tap.aggregateDeviceID,
                                              scope: kAudioObjectPropertyScopeInput,
                                              stemURL: stem, format: .alac)
            return run(chain: chain, seconds: seconds, description: bundleID, stemURL: stem)
        } catch {
            FileHandle.standardError.write("tap error: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    static func recordMic(seconds: Double, outDir: URL) -> Int32 {
        guard let deviceID = AudioProperty.defaultInputDeviceID else { return 1 }
        let stem = outDir.appendingPathComponent("stem-mic.caf")
        do {
            let chain = try CaptureChain.make(deviceID: deviceID,
                                              scope: kAudioObjectPropertyScopeInput,
                                              stemURL: stem, format: .alac)
            return run(chain: chain, seconds: seconds, description: "mic", stemURL: stem)
        } catch {
            FileHandle.standardError.write("mic error: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func run(chain: CaptureChain, seconds: Double, description: String, stemURL: URL) -> Int32 {
        var teardownDone = false
        chain.onLevel = { level in
            // `%-30s` with an NSString is undefined behavior — pad the bar manually.
            let filled = min(max(Int(level * 30), 0), 30)
            let bar = String(repeating: "█", count: filled) + String(repeating: " ", count: 30 - filled)
            print("  [\(bar)] \(description)")
        }
        chain.onEnded = { _ in teardownDone = true }
        do {
            try chain.start()
        } catch {
            FileHandle.standardError.write("start error: \(error)\n".data(using: .utf8)!)
            return 1
        }
        print("recording \(seconds)s from \(description)…")
        // Pump the main run loop instead of Thread.sleep: meter bars and the
        // end callback are delivered on the main queue, and teardown (including
        // the file close) now runs asynchronously off the IOProc thread — so we
        // wait for onEnded before inspecting the written file.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        chain.stop(reason: "sessionEnd")
        while !teardownDone {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: stemURL.path))?[.size] as? Int) ?? 0
        print("wrote \(stemURL.path) (\(size) bytes)")
        return 0
    }
}
