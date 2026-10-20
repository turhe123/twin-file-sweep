import SwiftUI
import AppKit

/// App entry point: one main window, a Settings window and menu commands.
@main
struct TwinFileSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        Window("TwinFileSweep", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder…") { model.chooseFolders() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Support / Donate ❤️") { Support.open() }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Quits the app when its only window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Opens the project's donation page.
enum Support {
    static func open() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
