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
            if phase == .background { onair_flush() }   // iOS may end the app without warning from here on
        }
    }
}

/// The hidden surface C++ runs on. One instance stays alive for the whole app.
struct OnAirView: UIViewRepresentable {
    func makeUIView(context: Context) -> OnAirMetalView { OnAirMetalView() }
    func updateUIView(_ view: OnAirMetalView, context: Context) {}
}
