import AppKit
import SwiftUI

@main
struct CablecarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(source: USBMediaSource())

    var body: some Scene {
        WindowGroup("Cablecar") {
            ContentView()
                .environment(model)
                .task { model.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Required when run as a bare SwiftPM executable (`swift run`) so the
        // window and menu bar appear; harmless inside a proper .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
