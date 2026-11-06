import AVFoundation
import OnAirCore
import SwiftUI

@main
struct OnAirApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRunner.shared.enter() }
            if phase == .active { BackgroundRunner.shared.leave() }
        }
    }
}

/// The hidden surface C++ runs on. One instance stays alive for the whole app.
struct OnAirView: UIViewRepresentable {
    func makeUIView(context: Context) -> OnAirMetalView { OnAirMetalView() }
    func updateUIView(_ view: OnAirMetalView, context: Context) {}
}

/// Keeps the receiver working with the screen off. The frame loop stops with the view, so a timer drives C++ instead, and a mode with no sound of its own plays
/// silence, because iOS keeps an app running in the background only while it is playing audio.
@MainActor final class BackgroundRunner {
    static let shared = BackgroundRunner()
    private var timer: Timer?
    private let silence = AVAudioEngine()
    private lazy var silentNode = AVAudioSourceNode { _, _, _, buffers in
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
        return noErr
    }

    func enter() {
        guard onair_is_started() else { return }
        onair_set_background(true)   // also saves the settings: iOS may end the app without warning from here on
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { onair_frame() }
        }
        guard onair_running() else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        if !silence.attachedNodes.contains(silentNode) {
            silence.attach(silentNode)
            silence.connect(silentNode, to: silence.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        }
        try? silence.start()
    }

    func leave() {
        timer?.invalidate()
        timer = nil
        silence.stop()
        guard onair_is_started() else { return }
        onair_set_background(false)
    }
}
