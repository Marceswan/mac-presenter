import AppKit
import PresenterCore
import SwiftUI

// CONTRACT: the prompter view agent implements this file. Do not change the public
// shape without updating every caller.

enum PrompterTheme: String, CaseIterable, Identifiable {
    case dark, light, amber

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "White on Black"
        case .light: "Black on White"
        case .amber: "Amber on Black"
        }
    }
}

struct PrompterStyle: Equatable {
    /// Point size of the script text.
    var fontSize: CGFloat = 56
    /// Line height multiple, for example 1.25.
    var lineSpacing: CGFloat = 1.25
    /// Empty space on each side, as a fraction of the view width. 0...0.4.
    var marginFraction: CGFloat = 0.1
    /// Vertical position of the reading line, as a fraction of the view height from the top. 0.1...0.9.
    var readingLine: CGFloat = 0.33
    /// Scroll response, 1 (slow, soft) ... 10 (fast).
    var scrollSpeed: CGFloat = 5
    /// Flip the text left to right for a beam-splitter teleprompter.
    var mirror: Bool = false
    var theme: PrompterTheme = .dark
}

/// Shows the script and scrolls so the word at `position` sits on the reading line.
struct PrompterView: NSViewRepresentable {
    let script: Script
    /// Index of the next word to read, `0...script.words.count`.
    let position: Int
    let style: PrompterStyle
    /// Called when the user scrolls by hand or with the arrow keys. The value is the
    /// index of the first word on the line at the reading line.
    var onUserScroll: (Int) -> Void
    /// Called when the user presses Space while the prompter has focus.
    var onToggleListening: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView() // STUB
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // STUB
    }
}
