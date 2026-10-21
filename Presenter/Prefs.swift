import Foundation

/// UserDefaults keys and default values. Views read them with `@AppStorage`.
enum Prefs {
    static let fontSize = "fontSize"
    static let lineSpacing = "lineSpacing"
    static let marginFraction = "marginFraction"
    static let readingLine = "readingLine"
    static let scrollSpeed = "scrollSpeed"
    static let mirror = "mirror"
    static let theme = "theme"
    static let showOverlay = "showOverlay"
    static let keepOnTop = "keepOnTop"
    static let localeIdentifier = "localeIdentifier"
    static let highlightSpokenWords = "highlightSpokenWords"

    static let defaultFontSize: Double = 56
    static let defaultLineSpacing: Double = 1.25
    static let defaultMarginFraction: Double = 0.1
    static let defaultReadingLine: Double = 0.33
    static let defaultScrollSpeed: Double = 5
    static let defaultMirror = false
    static let defaultTheme = PrompterTheme.dark.rawValue
    static let defaultShowOverlay = true
    static let defaultKeepOnTop = false
    static let defaultLocaleIdentifier = ""
    static let defaultHighlightSpokenWords = true

    static let fontSizeRange: ClosedRange<Double> = 24...160
    static let fontSizeStep: Double = 4
}
