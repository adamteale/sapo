import Foundation
import Combine
import AVFoundation

/// Plays a single stem file for in-app preview. One active player at a time;
/// starting a new preview stops the previous one.
final class TrackPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingStemID: UUID?
    private var player: AVAudioPlayer?

    func play(_ stem: StemRecord, folder: URL) {
        stop()
        let url = folder.appendingPathComponent(stem.fileName)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.play()
        playingStemID = stem.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingStemID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingStemID = nil
    }
}
