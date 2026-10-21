import AppKit
import PresenterCore
import SwiftUI

struct ContentView: View {
    @Environment(PrompterModel.self) private var model

    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.lineSpacing) private var lineSpacing = Prefs.defaultLineSpacing
    @AppStorage(Prefs.marginFraction) private var marginFraction = Prefs.defaultMarginFraction
    @AppStorage(Prefs.readingLine) private var readingLine = Prefs.defaultReadingLine
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = Prefs.defaultScrollSpeed
    @AppStorage(Prefs.mirror) private var mirror = Prefs.defaultMirror
    @AppStorage(Prefs.theme) private var themeRaw = Prefs.defaultTheme
    @AppStorage(Prefs.showOverlay) private var showOverlay = Prefs.defaultShowOverlay
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = Prefs.defaultKeepOnTop
    @AppStorage(Prefs.highlightSpokenWords) private var highlightSpokenWords = Prefs.defaultHighlightSpokenWords

    private var style: PrompterStyle {
        PrompterStyle(
            fontSize: CGFloat(fontSize),
            lineSpacing: CGFloat(lineSpacing),
            marginFraction: CGFloat(marginFraction),
            readingLine: CGFloat(readingLine),
            scrollSpeed: CGFloat(scrollSpeed),
            mirror: mirror,
            theme: PrompterTheme(rawValue: themeRaw) ?? .dark,
            highlightSpokenWords: highlightSpokenWords)
    }

    var body: some View {
        Group {
            switch model.mode {
            case .edit:
                EditorScreen()
            case .prompt:
                PrompterScreen(style: style, showOverlay: showOverlay)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(WindowLevelHelper(floating: keepOnTop))
        .background {
            // Second shortcut for "Larger Text": Command-Plus.
            Button("Larger Text") {
                fontSize = min(Prefs.fontSizeRange.upperBound, fontSize + Prefs.fontSizeStep)
            }
            .keyboardShortcut("+")
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Label("Edit", systemImage: "square.and.pencil").tag(PrompterModel.Mode.edit)
                Label("Prompt", systemImage: "play.rectangle").tag(PrompterModel.Mode.prompt)
            }
            .pickerStyle(.segmented)
            .help("Switch between editor and prompter")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleListening()
            } label: {
                Label(model.isActive ? "Stop Listening" : "Start Listening",
                      systemImage: model.isActive ? "stop.fill" : "mic")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isActive ? .red : .secondary)
            .help(model.isActive ? "Stop listening" : "Start listening")

            Button {
                model.restart()
            } label: {
                Label("Back to Start", systemImage: "backward.end")
            }
            .help("Go back to the start of the script")

            Button {
                fontSize = max(Prefs.fontSizeRange.lowerBound, fontSize - Prefs.fontSizeStep)
            } label: {
                Label("Smaller Text", systemImage: "textformat.size.smaller")
            }
            .help("Make the text smaller")

            Button {
                fontSize = min(Prefs.fontSizeRange.upperBound, fontSize + Prefs.fontSizeStep)
            } label: {
                Label("Larger Text", systemImage: "textformat.size.larger")
            }
            .help("Make the text larger")

            Toggle(isOn: $mirror) {
                Label("Mirror Text", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip the text left to right")

            Toggle(isOn: $keepOnTop) {
                Label("Keep on Top", systemImage: keepOnTop ? "pin.fill" : "pin")
            }
            .help("Keep the window above other windows")
        }
    }
}

// MARK: - Editor

private struct EditorScreen: View {
    @Environment(PrompterModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { model.scriptText }, set: { model.setScriptText($0) }))
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Text("\(model.wordCount) words \u{00B7} about \(model.estimatedMinutes) min")
                Spacer()
                Text("Text in [brackets] is a cue. The prompter does not wait for cues.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Prompter

private struct PrompterScreen: View {
    @Environment(PrompterModel.self) private var model
    let style: PrompterStyle
    let showOverlay: Bool

    var body: some View {
        PrompterView(
            script: model.script,
            position: model.position,
            style: style,
            onUserScroll: { model.jump(to: $0) },
            onToggleListening: { model.toggleListening() })
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if showOverlay {
                    StatusOverlay()
                        .padding(.bottom, 24)
                        .padding(.horizontal, 24)
                }
            }
    }
}

private struct StatusOverlay: View {
    @Environment(PrompterModel.self) private var model

    private var statusText: String {
        switch model.state {
        case .idle: "Not listening \u{2014} press Space"
        case .preparing(let message): message
        case .listening: "Listening"
        case .failed(let message): message
        }
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var wordLabel: String {
        let total = model.wordCount
        guard total > 0 else { return "No words" }
        return "word \(min(model.position + 1, total)) of \(total)"
    }

    var body: some View {
        HStack(spacing: 12) {
            microphone

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(isFailed ? Color.red : Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isActive, !model.heard.isEmpty {
                    Text(model.heard)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Text(wordLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var microphone: some View {
        if case .listening = model.state {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .scaleEffect(1 + CGFloat(min(max(model.level, 0), 1)) * 0.5)
                .animation(.easeOut(duration: 0.1), value: model.level)
                .frame(width: 28)
        } else if model.isActive {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28)
        } else {
            Image(systemName: "mic.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
        }
    }
}

// MARK: - Keep on Top

private struct WindowLevelHelper: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async {
            view.window?.level = level
        }
    }
}
