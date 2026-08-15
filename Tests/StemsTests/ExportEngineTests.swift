import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("ExportEngine") struct ExportEngineTests {
    /// Builds a real session folder with two WAV stems (test tones).
    static func makeSession() throws -> (folder: URL, manifest: SessionManifest, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-x-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeSessionFolder(start: start)

        func writeTone(name: String, rate: Double, seconds: Double) throws -> String {
            let fileName = "tone-\(name).wav"
            let url = folder.appendingPathComponent(fileName)
            let writer = try StemWriter(url: url,
                clientFormat: AudioStreamBasicDescription(
                    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0),
                format: .wav)
            let frames = UInt32(rate * seconds)
            var phase: Float = 0
            let inc: Float = Float(2 * Double.pi * 440 / rate)
            var written: UInt32 = 0
            while written < frames {
                let n = min(4096, frames - written)
                var samples = [Float](repeating: 0, count: Int(n) * 2)
                for f in 0..<Int(n) { let v = sin(phase) * 0.4; phase += inc
                    samples[f * 2] = v; samples[f * 2 + 1] = v }
                try samples.withUnsafeMutableBytes { raw in
                    var abl = AudioBufferList(mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: n * 8, mData: raw.baseAddress))
                    try writer.write(&abl, frameCount: n)
                }
                written += n
            }
            writer.close()
            return fileName
        }

        let chrome = SourceDescriptor(id: "com.google.Chrome", kind: .application, name: "Chrome",
                                      bundleIdentifier: "com.google.Chrome", deviceUID: nil)
        let mic = SourceDescriptor(id: "mic-uid", kind: .microphone, name: "Mic",
                                   bundleIdentifier: nil, deviceUID: "mic-uid")
        let manifest = SessionManifest(identifier: UUID(), title: folder.lastPathComponent,
                                       startTime: start, endTime: start.addingTimeInterval(2),
                                       stemFormat: .wav, stems: [
            StemRecord(source: chrome, fileName: try writeTone(name: "a", rate: 44_100, seconds: 2),
                       sampleRate: 44_100, channelCount: 2, startTime: start, endTime: nil, endEvent: nil),
            StemRecord(source: mic, fileName: try writeTone(name: "b", rate: 48_000, seconds: 2),
                       sampleRate: 48_000, channelCount: 2, startTime: start, endTime: nil, endEvent: nil),
        ], appVersion: "0")
        try store.save(manifest, to: folder)
        return (folder, manifest, { try? FileManager.default.removeItem(at: root) })
    }

    @Test func combinedM4AExportProducesDecodableFile() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: Set(manifest.stems.map(\.id)),
                                    scope: .combined, format: .m4a, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 1)
        let out = try AVAudioFile(forReading: files[0])
        #expect(out.length > 80_000) // ~2s at 48k
        #expect(files[0].lastPathComponent.contains("Mix"))
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func groupedExportProducesOneFilePerKind() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: Set(manifest.stems.map(\.id)),
                                    scope: .grouped, format: .wav, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 2)
        #expect(files.contains { $0.lastPathComponent.contains("Applications") })
        #expect(files.contains { $0.lastPathComponent.contains("Microphone") })
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func individualExportHonorsSelection() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: [manifest.stems[0].id],
                                    scope: .individual, format: .wav, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent.contains("Chrome"))
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func exportFailsWhenSelectedStemFileMissing() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        // Delete the first stem's file so it is missing from disk but still in the manifest.
        let missingName = manifest.stems[0].fileName
        try FileManager.default.removeItem(at: folder.appendingPathComponent(missingName))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: [manifest.stems[0].id],
                                    scope: .combined, format: .wav, destination: dest)
        do {
            _ = try ExportEngine.export(request)
            Issue.record("expected export to throw for missing stem file")
        } catch {
            #expect("\(error)".contains(missingName))
        }
    }
}
