import SwiftUI
import AVFoundation

@main
struct MSPlayerApp: App {

    @StateObject private var store = Store.shared

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            NSLog("[msplayer] audio session: %@", String(describing: error))
        }
    }
}
