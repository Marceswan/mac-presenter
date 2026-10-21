import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PresenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PrompterModel()

    var body: some Scene {
        Window("Presenter", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            PrompterCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

struct PrompterCommands: Commands {
    let model: PrompterModel
    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.mirror) private var mirror = Prefs.defaultMirror
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = Prefs.defaultKeepOnTop

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Script\u{2026}") { model.openScript() }
                .keyboardShortcut("o")
        }

        CommandMenu("Prompter") {
            Button(model.mode == .edit ? "Show Prompter" : "Show Editor") { model.toggleMode() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(model.isActive ? "Stop Listening" : "Start Listening") { model.toggleListening() }
                .keyboardShortcut("l")
            Button("Back to Start") { model.restart() }
                .keyboardShortcut("r")

            Divider()

            Button("Larger Text") { fontSize = min(Prefs.fontSizeRange.upperBound, fontSize + Prefs.fontSizeStep) }
                .keyboardShortcut("=")
            Button("Smaller Text") { fontSize = max(Prefs.fontSizeRange.lowerBound, fontSize - Prefs.fontSizeStep) }
                .keyboardShortcut("-")

            Divider()

            Toggle("Mirror Text", isOn: $mirror)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Keep on Top", isOn: $keepOnTop)
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}
