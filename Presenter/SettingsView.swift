import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.fontSize) private var fontSize = Prefs.defaultFontSize
    @AppStorage(Prefs.lineSpacing) private var lineSpacing = Prefs.defaultLineSpacing
    @AppStorage(Prefs.marginFraction) private var marginFraction = Prefs.defaultMarginFraction
    @AppStorage(Prefs.readingLine) private var readingLine = Prefs.defaultReadingLine
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = Prefs.defaultScrollSpeed
    @AppStorage(Prefs.mirror) private var mirror = Prefs.defaultMirror
    @AppStorage(Prefs.theme) private var theme = Prefs.defaultTheme
    @AppStorage(Prefs.showOverlay) private var showOverlay = Prefs.defaultShowOverlay
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = Prefs.defaultKeepOnTop
    @AppStorage(Prefs.localeIdentifier) private var localeIdentifier = Prefs.defaultLocaleIdentifier
    @AppStorage(Prefs.highlightSpokenWords) private var highlightSpokenWords = Prefs.defaultHighlightSpokenWords

    @State private var locales: [Locale] = []

    private struct LocaleOption: Identifiable {
        let id: String
        let title: String
    }

    private var localeOptions: [LocaleOption] {
        var options = locales
            .map { LocaleOption(id: $0.identifier, title: Self.name(for: $0.identifier)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !localeIdentifier.isEmpty, !options.contains(where: { $0.id == localeIdentifier }) {
            options.append(LocaleOption(id: localeIdentifier, title: Self.name(for: localeIdentifier)))
        }
        return options
    }

    private static func name(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $fontSize, in: Prefs.fontSizeRange, step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $lineSpacing, in: 1.0...2.0)
                        Text(lineSpacing, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Side margin") {
                    HStack {
                        Slider(value: $marginFraction, in: 0...0.35)
                        Text(marginFraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("Theme", selection: $theme) {
                    ForEach(PrompterTheme.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
            }

            Section("Scrolling") {
                LabeledContent("Reading line") {
                    Slider(value: $readingLine, in: 0.15...0.6) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Higher")
                    } maximumValueLabel: {
                        Text("Lower")
                    }
                }
                LabeledContent("Scroll speed") {
                    Slider(value: $scrollSpeed, in: 1...10, step: 1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Softer")
                    } maximumValueLabel: {
                        Text("Faster")
                    }
                }
                Toggle("Mirror text", isOn: $mirror)
                Toggle("Highlight each word you speak", isOn: $highlightSpokenWords)
            }

            Section("Speech") {
                Picker("Language", selection: $localeIdentifier) {
                    Text("System (\(Locale.current.identifier))").tag("")
                    ForEach(localeOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Toggle("Show status overlay", isOn: $showOverlay)
                Toggle("Keep window on top", isOn: $keepOnTop)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            locales = await SpeechListener.supportedLocales()
        }
    }
}
