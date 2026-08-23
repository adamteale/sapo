import SwiftUI

struct LevelMeterView: View {
    let level: Float
    /// Decaying peak-hold position; refreshed on the shared 10Hz tick below.
    @State private var peak: Float = 0

    /// One 10Hz tick shared by every meter row (a single ConnectablePublisher
    /// instance — subscriptions share the timer), matching RecorderView's
    /// refresh cadence. Decay only runs while a row is on screen.
    private static let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                // Peak-hold: a 2pt tick centered on the decaying peak position,
                // hidden at zero so it can't stick out past the track's start.
                Capsule()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .opacity(peak > 0 ? 1 : 0)
                    .offset(x: geo.size.width * CGFloat(min(max(peak, 0), 1)) - 1)
            }
        }
        .frame(height: 6)
        .onReceive(Self.tick) { _ in
            peak = max(peak * 0.85, level)
        }
    }
}
