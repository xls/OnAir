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

/// The C++ drawing surface. One instance stays alive for the whole app: native pages cover it, they never replace it.
struct OnAirView: UIViewRepresentable {
    func makeUIView(context: Context) -> OnAirMetalView { OnAirMetalView() }
    func updateUIView(_ view: OnAirMetalView, context: Context) {}
}
