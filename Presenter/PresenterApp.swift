import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: PrompterModel?
    var reopenWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.flushSave() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your latest changes could not be saved"
        alert.informativeText = model.fileError ?? "Keep Presenter open and try saving again."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Quit Without Saving")
        let response = alert.runModal()
        model.fileError = nil
        if response == .alertSecondButtonReturn { return .terminateNow }
        DispatchQueue.main.async { self.reopenWindow?() }
        return .terminateCancel
    }
}

@main
struct PresenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PrompterModel()
    @State private var updater = AppUpdater()

    var body: some Scene {
        Window("Presenter", id: "main") {
            MainWindowContent(model: model, appDelegate: appDelegate, updater: updater)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            PrompterCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

private struct MainWindowContent: View {
    let model: PrompterModel
    let appDelegate: AppDelegate
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(model)
            .onAppear {
                appDelegate.model = model
                appDelegate.reopenWindow = { openWindow(id: "main") }
                reportPresentationState()
            }
            .onChange(of: model.mode) { reportPresentationState() }
            .onChange(of: model.isActive) { reportPresentationState() }
    }

    private func reportPresentationState() {
        updater.presentationStateChanged(mode: model.mode, isListening: model.isActive)
    }
}

struct PrompterCommands: Commands {
    let model: PrompterModel
    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.mirror) private var mirror = Prefs.defaultMirror
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = Prefs.defaultKeepOnTop

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Presentation") { model.newPresentation() }
                .keyboardShortcut("n")
            Button("Import Presentation\u{2026}") { model.openScript() }
                .keyboardShortcut("o")
            Button("Presentation Library\u{2026}") { model.showLibrary() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Presentation") { model.flushSave() }
                .keyboardShortcut("s")
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
