import AppKit
import PresenterCore
import QuartzCore
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

    // MARK: Colors

    private static let amberBase = NSColor(srgbRed: 1.0, green: 201.0 / 255.0, blue: 77.0 / 255.0, alpha: 1)

    /// Fill behind the script.
    var background: NSColor {
        switch self {
        case .dark, .amber: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    /// Color of text that is not yet spoken.
    var text: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .amber: Self.amberBase
        }
    }

    /// Color of text that the speaker has passed.
    var spoken: NSColor { text.withAlphaComponent(0.35) }

    /// Color of cues such as `[PAUSE]`.
    var cue: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 0.40, green: 0.78, blue: 1.0, alpha: 1)
        case .light: NSColor(srgbRed: 0.0, green: 0.40, blue: 0.80, alpha: 1)
        case .amber: NSColor(srgbRed: 1.0, green: 0.54, blue: 0.36, alpha: 1)
        }
    }

    /// Faint band behind the reading line.
    var band: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
        case .light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06)
        case .amber: Self.amberBase.withAlphaComponent(0.10)
        }
    }

    /// Triangles at the left and right edge of the reading line.
    var marker: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.35, alpha: 1)
        case .light: NSColor(srgbRed: 0.85, green: 0.19, blue: 0.15, alpha: 1)
        case .amber: Self.amberBase
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
    /// Play a short gradient animation on each word the speaker has just passed.
    var highlightSpokenWords: Bool = true
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
    /// True while the microphone feeds the follower. The view then moves a little ahead of
    /// `position` at the speaking pace, so the recognizer delay does not show as lag.
    var isListening: Bool = false

    func makeNSView(context: Context) -> PrompterTextView {
        let view = PrompterTextView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PrompterTextView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PrompterTextView) {
        view.onUserScroll = onUserScroll
        view.onToggleListening = onToggleListening
        view.update(script: script, position: position, style: style, isListening: isListening)
    }
}

// MARK: - Prompter view

/// Draws the script with TextKit 1 and scrolls it with a critically damped spring.
///
/// `offset` is the container y coordinate that is shown at the reading line. The view
/// does not use NSScrollView, so it has full control of smooth scrolling and mirroring.
final class PrompterTextView: NSView {

    // MARK: Hooks

    var onUserScroll: ((Int) -> Void)?
    var onToggleListening: (() -> Void)?
    /// Time source for the word animations. Tests replace it to freeze the clock.
    var animationClock: () -> CFTimeInterval = { CACurrentMediaTime() }

    // MARK: Model

    private(set) var script = Script(text: "")
    private(set) var position = 0
    private(set) var style = PrompterStyle()
    private var isConfigured = false

    // MARK: TextKit

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private static let containerHeight: CGFloat = 10_000_000

    private var containerWidth: CGFloat = 100
    private var cachedTextHeight: CGFloat?
    private var fontAscender: CGFloat = 0
    private var fontDescender: CGFloat = 0
    private var fontCapHeight: CGFloat = 0
    private var lineHeight: CGFloat = 0
    private var firstContentCharacter = -1
    private var lastContentCharacter = -1
    /// Scroll target per word index. Layout changes clear it.
    private var targetCache: [Int: CGFloat] = [:]

    // MARK: Colors

    private var appliedSplit: Int?
    private var appliedTheme: PrompterTheme?

    // MARK: Scrolling

    private var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var springRunning = false
    /// The spring is faster than `scrollSpeed` alone: the target already moves
    /// continuously, so the offset follows it with less delay.
    private static let springGain: CGFloat = 1.4
    private var omega: CGFloat = 5 * springGain
    /// Inside this distance (points) the offset follows the target directly.
    private static let trackingRadius: CGFloat = 2

    // MARK: Pace

    /// The pace lead moves the view ahead of `position` while the speaker reads. It hides
    /// the delay of the recognizer.
    private var isListening = false
    /// Speaking rate in words per second. This is an exponential moving average.
    private var paceRate: Double = 2.5
    /// Time of the last forward update that the lead grows from. Nil when the lead is idle.
    private var lastForwardTime: CFTimeInterval?
    /// Lead in words at `lastForwardTime`. It is never negative.
    private var leadStart: Double = 0

    private enum Pace {
        /// Forward updates of this many words feed the rate estimate.
        static let maxStep = 6
        /// Intervals outside this range (seconds) do not feed the rate estimate.
        static let minInterval: CFTimeInterval = 0.02
        static let maxInterval: CFTimeInterval = 2.0
        static let smoothing = 0.4
        static let rateRange = 0.5...5.0
        /// The lead stops growing this long (seconds) after the last update.
        static let leadWindow: CFTimeInterval = 1.2
        /// The lead never passes this many words.
        static let maxLead = 2.0
    }

    private var displayLink: CADisplayLink?
    private let linkProxy = DisplayLinkProxy()
    private var lastTick: CFTimeInterval?

    private var isUserScrolling = false
    private var lastScrollTime: CFTimeInterval = 0
    private var scrollTimer: Timer?
    private static let scrollSettleDelay: TimeInterval = 0.35

    // MARK: Word animations

    private struct WordGlow {
        let characterRange: NSRange
        let start: CFTimeInterval
    }

    private enum Glow {
        static let sweepDuration: CFTimeInterval = 0.35
        static let fadeDuration: CFTimeInterval = 0.55
        static var totalDuration: CFTimeInterval { sweepDuration + fadeDuration }
        static let stagger: CFTimeInterval = 0.04
        static let maxWordsPerMove = 6
        static let maxPositionJump = 12
        static let maxActive = 12
        static let haloAlpha: CGFloat = 0.15
        static let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0, alpha: 1),
                CGColor(srgbRed: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0, alpha: 1),
                CGColor(srgbRed: 0xF9 / 255.0, green: 0x73 / 255.0, blue: 0x16 / 255.0, alpha: 1),
            ] as CFArray,
            locations: [0, 0.5, 1])!
    }

    private var glows: [WordGlow] = []

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        linkProxy.view = self
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.backgroundLayoutEnabled = false
        layoutManager.allowsNonContiguousLayout = false
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: containerWidth, height: Self.containerHeight)
        layerContentsRedrawPolicy = .duringViewResize
    }

    deinit {
        displayLink?.invalidate()
        scrollTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Updates from SwiftUI

    func update(
        script newScript: Script,
        position newPosition: Int,
        style newStyle: PrompterStyle,
        isListening newListening: Bool = false
    ) {
        let oldStyle = style
        let oldPosition = position
        let oldListening = isListening
        let textChanged = !isConfigured || newScript.text != script.text
        let fontChanged = !isConfigured
            || oldStyle.fontSize != newStyle.fontSize
            || oldStyle.lineSpacing != newStyle.lineSpacing
        let themeChanged = !isConfigured || oldStyle.theme != newStyle.theme
        let wasConfigured = isConfigured
        let now = animationClock()
        // Where the view is now, with the lead of the old state.
        let displayedBefore = displayedPosition(now: now)

        script = newScript
        style = newStyle
        isConfigured = true
        isListening = newListening
        omega = min(max(newStyle.scrollSpeed, 0.5), 20) * Self.springGain
        let clamped = max(0, min(newPosition, newScript.words.count))

        if !newStyle.highlightSpokenWords { glows.removeAll() }

        if textChanged || fontChanged {
            cancelUserScroll()
            glows.removeAll()
            resetLead()
            rebuildText()
            position = clamped
            applyColors(force: true)
            snapToTarget()
            return
        }

        let widthChanged = syncContainerWidth()
        position = clamped
        trackPace(from: oldPosition, wasListening: oldListening, displayedBefore: displayedBefore, now: now)
        applyColors(force: themeChanged)
        if widthChanged && !isUserScrolling {
            snapToTarget()
        } else if (clamped != oldPosition || newListening != oldListening) && !isUserScrolling {
            if wasConfigured && clamped != oldPosition { startGlows(from: oldPosition, to: clamped) }
            animate(to: scrollTarget(now: now))
        }
        needsDisplay = true
    }

    // MARK: Pace lead

    /// Updates the speaking rate and the lead after the position or the listening state changed.
    private func trackPace(
        from oldPosition: Int,
        wasListening: Bool,
        displayedBefore: Double,
        now: CFTimeInterval
    ) {
        if isUserScrolling {
            resetLead()
            return
        }
        let delta = position - oldPosition
        if delta > 0 {
            if isListening {
                if (1...Pace.maxStep).contains(delta), let last = lastForwardTime {
                    let interval = now - last
                    if interval >= Pace.minInterval, interval <= Pace.maxInterval {
                        let sample = Double(delta) / interval
                        let blended = paceRate + Pace.smoothing * (sample - paceRate)
                        paceRate = min(max(blended, Pace.rateRange.lowerBound), Pace.rateRange.upperBound)
                    }
                }
                lastForwardTime = now
            } else {
                lastForwardTime = nil
            }
            // The view never moves backward: keep the part of the old lead that is still ahead.
            leadStart = max(0, displayedBefore - Double(position))
        } else if delta < 0 {
            resetLead()
        } else if wasListening && !isListening {
            // Listening stopped. Hold the lead so the text does not move backward.
            leadStart = max(0, displayedBefore - Double(position))
            lastForwardTime = nil
        }
    }

    private func resetLead() {
        leadStart = 0
        lastForwardTime = nil
    }

    /// The lead in words at `now`. It grows at the speaking rate, up to one word, and stops
    /// growing `Pace.leadWindow` seconds after the last update.
    private func currentLead(now: CFTimeInterval) -> Double {
        guard isListening, let last = lastForwardTime else { return leadStart }
        let elapsed = min(max(now - last, 0), Pace.leadWindow)
        return max(leadStart, min(paceRate * elapsed, Pace.maxLead))
    }

    /// True while the lead can still grow and the view has to keep moving.
    private func leadIsGrowing(now: CFTimeInterval) -> Bool {
        guard isListening, !isUserScrolling, let last = lastForwardTime else { return false }
        let elapsed = now - last
        return elapsed < Pace.leadWindow && paceRate * elapsed < Pace.maxLead
    }

    /// The fractional position that the view shows: the integer position plus the lead.
    private func displayedPosition(now: CFTimeInterval) -> Double {
        min(Double(position) + currentLead(now: now), Double(script.words.count))
    }

    /// The fractional position that the view shows now. Tests read it.
    var fractionalPosition: Double { displayedPosition(now: animationClock()) }

    /// The scroll offset in points. Tests read it.
    var currentOffset: CGFloat { offset }

    /// The offset that the view moves toward now.
    private func scrollTarget(now: CFTimeInterval) -> CGFloat {
        offset(forPosition: displayedPosition(now: now))
    }

    /// Linear interpolation between the targets of the two words around `fractional`.
    private func offset(forPosition fractional: Double) -> CGFloat {
        let count = script.words.count
        let bounded = min(max(fractional, 0), Double(count))
        let lower = Int(bounded.rounded(.down))
        let part = bounded - Double(lower)
        let start = targetOffset(for: lower)
        guard part > 0.000_1, lower < count else { return start }
        let end = targetOffset(for: lower + 1)
        return start + CGFloat(part) * (end - start)
    }

    // MARK: Text

    private func rebuildText() {
        let size = max(style.fontSize, 8)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let cueSize = size * 0.75
        let italic = font.fontDescriptor.withSymbolicTraits(.italic)
        let cueFont = NSFont(descriptor: italic, size: cueSize)
            ?? NSFont.systemFont(ofSize: cueSize, weight: .semibold)
        let spacing = max(style.lineSpacing, 0.5)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = spacing
        paragraph.paragraphSpacing = size * 0.6

        fontAscender = font.ascender
        fontDescender = font.descender
        fontCapHeight = font.capHeight
        lineHeight = ((font.ascender - font.descender + font.leading) * spacing).rounded()

        let attributed = NSMutableAttributedString(
            string: script.text,
            attributes: [.font: font, .paragraphStyle: paragraph])
        for range in script.cueRanges where NSMaxRange(range) <= attributed.length {
            attributed.addAttribute(.font, value: cueFont, range: range)
        }

        syncContainerWidth()
        textStorage.setAttributedString(attributed)
        cachedTextHeight = nil
        targetCache.removeAll()
        appliedSplit = nil
        appliedTheme = nil
        findContentBounds()
    }

    private func findContentBounds() {
        let units = Array(script.text.utf16)
        let isBlank: (UInt16) -> Bool = { unit in
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        firstContentCharacter = units.firstIndex(where: { !isBlank($0) }) ?? -1
        lastContentCharacter = units.lastIndex(where: { !isBlank($0) }) ?? -1
    }

    /// Updates the container width from the view width and margin. Returns true on change.
    @discardableResult
    private func syncContainerWidth() -> Bool {
        let margin = min(max(style.marginFraction, 0), 0.45)
        let width = max(100, bounds.width * (1 - 2 * margin))
        guard abs(width - containerWidth) > 0.01 else { return false }
        containerWidth = width
        textContainer.size = NSSize(width: width, height: Self.containerHeight)
        cachedTextHeight = nil
        targetCache.removeAll()
        return true
    }

    private var textHeight: CGFloat {
        if let cached = cachedTextHeight { return cached }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        cachedTextHeight = height
        return height
    }

    override func layout() {
        super.layout()
        handleWidthChange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        handleWidthChange()
    }

    private func handleWidthChange() {
        if syncContainerWidth(), isConfigured {
            if isUserScrolling {
                offset = min(max(offset, 0), textHeight)
                target = offset
            } else {
                snapToTarget()
            }
        }
        needsDisplay = true
    }

    // MARK: Colors

    /// The character index where unspoken text starts.
    private func splitLocation() -> Int {
        let length = textStorage.length
        if script.words.isEmpty { return 0 }
        if position >= script.words.count { return length }
        return min(script.words[position].range.location, length)
    }

    /// Colors text with temporary attributes. They change only the drawing color, so
    /// they never invalidate glyphs or layout.
    private func applyColors(force: Bool = false) {
        let length = textStorage.length
        guard length > 0 else {
            appliedSplit = nil
            return
        }
        let split = splitLocation()
        let theme = style.theme
        if force || appliedSplit == nil || appliedTheme != theme {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
            for cue in script.cueRanges where NSMaxRange(cue) <= length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.cue, forCharacterRange: cue)
            }
            paint(NSRange(location: 0, length: split), theme.spoken)
            paint(NSRange(location: split, length: length - split), theme.text)
        } else if let applied = appliedSplit, applied != split {
            let low = min(applied, split)
            let range = NSRange(location: low, length: max(applied, split) - low)
            paint(range, split > applied ? theme.spoken : theme.text)
        } else {
            return
        }
        appliedSplit = split
        appliedTheme = theme
        needsDisplay = true
    }

    /// Colors the part of `range` that is not inside a cue. Cues keep the cue color.
    private func paint(_ range: NSRange, _ color: NSColor) {
        guard range.length > 0 else { return }
        let cues = script.cueRanges
        let end = NSMaxRange(range)
        var location = range.location

        // Binary search: first cue that ends after `location`.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(cues[mid]) <= location { low = mid + 1 } else { high = mid }
        }

        while location < end {
            guard low < cues.count, cues[low].location < end else {
                add(color, NSRange(location: location, length: end - location))
                break
            }
            let cue = cues[low]
            if cue.location > location {
                add(color, NSRange(location: location, length: cue.location - location))
            }
            location = max(location, NSMaxRange(cue))
            low += 1
        }
    }

    private func add(_ color: NSColor, _ range: NSRange) {
        layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
    }

    // MARK: Targets

    /// The container y coordinate for the word at `position`.
    ///
    /// The target is continuous inside a line. It starts at the center of the line and
    /// moves toward the center of the next line as the word start moves from the left to
    /// the right end of the line. The text glides up while the speaker reads across a
    /// line, and arrives at the next line when the line ends. The first word of a line
    /// sits exactly on the reading line.
    private func targetOffset(for position: Int) -> CGFloat {
        guard textStorage.length > 0 else { return 0 }
        let index = max(0, min(position, script.words.count))
        if let cached = targetCache[index] { return cached }
        let character = startCharacter(forWordIndex: index)
        guard character >= 0 else { return 0 }
        let value = glideTarget(forCharacter: min(character, textStorage.length - 1))
        targetCache[index] = value
        return value
    }

    /// The character where the word at `index` starts. The index `words.count` stands for
    /// the end of the script and maps to the last character that is not blank.
    private func startCharacter(forWordIndex index: Int) -> Int {
        if script.words.isEmpty { return firstContentCharacter }
        if index >= script.words.count { return lastContentCharacter }
        return script.words[index].range.location
    }

    /// The center of the line that holds `character`, plus the share of the way to the
    /// next line that the character start has covered along its line.
    private func glideTarget(forCharacter character: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var lineGlyphs = NSRange()
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let center = lineCenter(forGlyph: glyph)

        // The next line fragment includes any paragraph gap. The last line has no next line.
        // The check uses characters, so it does not lay out the rest of the script.
        let lineCharacters = layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let nextCenter = NSMaxRange(lineCharacters) < textStorage.length
            ? lineCenter(forGlyph: NSMaxRange(lineGlyphs))
            : center + lineHeight

        let startX = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
        let fraction = used.width > 1 ? min(max((startX - used.minX) / used.width, 0), 1) : 0
        return center + fraction * (nextCenter - center)
    }

    /// The visual center of the text on the line that holds `glyph`.
    ///
    /// `lineHeightMultiple` adds the extra space above the glyphs, so the middle of the
    /// line fragment sits above the middle of the glyphs. The center of the cap height
    /// is the middle of what the speaker reads.
    private func lineCenter(forGlyph glyph: Int) -> CGFloat {
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        return baseline - fontCapHeight / 2
    }

    private func snapToTarget() {
        target = scrollTarget(now: animationClock())
        offset = target
        velocity = 0
        springRunning = false
        needsDisplay = true
        pauseLinkIfIdle()
    }

    private func animate(to newTarget: CGFloat) {
        target = newTarget
        let settled = abs(target - offset) < 0.3 && abs(velocity) < 1
        if window == nil || settled {
            offset = target
            velocity = 0
            springRunning = false
            needsDisplay = true
        } else {
            springRunning = true
        }
        if springRunning || leadIsGrowing(now: animationClock()) {
            ensureLinkRunning()
        } else {
            pauseLinkIfIdle()
        }
    }

    // MARK: Display link

    private func ensureLinkRunning() {
        guard window != nil else { return }
        if displayLink == nil {
            let link = displayLink(target: linkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = nil
        }
        if let link = displayLink, link.isPaused {
            lastTick = nil
            link.isPaused = false
        }
    }

    private func pauseLinkIfIdle() {
        guard !springRunning, glows.isEmpty, !leadIsGrowing(now: animationClock()),
              let link = displayLink, !link.isPaused else { return }
        link.isPaused = true
        lastTick = nil
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let elapsed = lastTick.map { timestamp - $0 } ?? link.duration
        lastTick = timestamp
        advanceFrame(dt: min(max(elapsed, 0), 1.0 / 30.0))
    }

    /// Runs one animation frame of `dt` seconds. The display link calls it. Tests call it
    /// with a fixed clock.
    func advanceFrame(dt: CFTimeInterval) {
        let now = animationClock()
        // While the lead is active the target moves with it. It also moves once more after
        // the lead stopped, so the view ends on the final lead.
        if isListening, !isUserScrolling, lastForwardTime != nil {
            target = scrollTarget(now: now)
            if abs(target - offset) > 0.001 || abs(velocity) > 0.001 { springRunning = true }
        }
        if springRunning {
            stepSpring(dt: CGFloat(dt))
        }
        pruneGlows(now: now)
        needsDisplay = true
        pauseLinkIfIdle()
    }

    /// Exact solution of a = w^2 (target - x) - 2 w v over one step. It stays stable
    /// for any step size and any speed.
    ///
    /// Inside `trackingRadius` the offset follows the target directly: the remaining
    /// distance and speed shrink to zero with a smoothstep curve. The curve is 1 at the
    /// edge of the zone, so a move that ends does not end with a hop.
    private func stepSpring(dt: CGFloat) {
        let w = omega
        let displacement = offset - target
        let c = velocity + w * displacement
        let decay = exp(-w * dt)
        var newDisplacement = (displacement + c * dt) * decay
        var newVelocity = (velocity - w * c * dt) * decay
        let distance = abs(newDisplacement)
        if distance < Self.trackingRadius {
            let u = distance / Self.trackingRadius
            let keep = u * u * (3 - 2 * u)
            newDisplacement *= keep
            newVelocity *= keep
        }
        if abs(newDisplacement) < 0.05 && abs(newVelocity) < 0.5 {
            offset = target
            velocity = 0
            springRunning = false
        } else {
            offset = target + newDisplacement
            velocity = newVelocity
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
            if springRunning || !glows.isEmpty || leadIsGrowing(now: animationClock()) { ensureLinkRunning() }
        } else {
            displayLink?.invalidate()
            displayLink = nil
            lastTick = nil
        }
    }

    // MARK: Word animations

    /// Starts the gradient on the words the speaker just passed.
    private func startGlows(from old: Int, to new: Int) {
        guard style.highlightSpokenWords, !isUserScrolling,
              (1...Glow.maxPositionJump).contains(new - old) else { return }
        let first = max(old, new - Glow.maxWordsPerMove)
        let now = animationClock()
        pruneGlows(now: now)
        for index in first..<new {
            glows.append(WordGlow(
                characterRange: script.words[index].range,
                start: now + Double(index - first) * Glow.stagger))
        }
        if glows.count > Glow.maxActive { glows.removeFirst(glows.count - Glow.maxActive) }
        ensureLinkRunning()
    }

    private func pruneGlows(now: CFTimeInterval) {
        guard !glows.isEmpty else { return }
        glows.removeAll { now - $0.start >= Glow.totalDuration }
    }

    private struct GlowFrame {
        let glyphRange: NSRange
        /// Bounds of the glyphs from ascender to descender, in view coordinates.
        let rect: NSRect
        let sweep: CGFloat
        let alpha: CGFloat
    }

    /// Frames of the animations that are running now and are inside the visible glyphs.
    private func glowFrames(visible: NSRange, origin: NSPoint, now: CFTimeInterval) -> [GlowFrame] {
        var frames: [GlowFrame] = []
        for glow in glows {
            let age = now - glow.start
            guard age >= 0, age < Glow.totalDuration else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: glow.characterRange, actualCharacterRange: nil)
            guard glyphRange.length > 0, NSIntersectionRange(glyphRange, visible).length > 0 else { continue }

            let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            let rect = NSRect(
                x: origin.x + bounds.minX,
                y: origin.y + baseline - fontAscender,
                width: bounds.width,
                height: fontAscender - fontDescender)

            let sweepProgress = CGFloat(min(age / Glow.sweepDuration, 1))
            let sweep = sweepProgress * sweepProgress * (3 - 2 * sweepProgress)
            let alpha: CGFloat
            if age < Glow.sweepDuration {
                alpha = 1
            } else {
                let p = CGFloat((age - Glow.sweepDuration) / Glow.fadeDuration)
                alpha = pow(1 - min(p, 1), 3)
            }
            frames.append(GlowFrame(glyphRange: glyphRange, rect: rect, sweep: sweep, alpha: alpha))
        }
        return frames
    }

    /// Soft rounded glow behind the word.
    private func drawHalo(_ frame: GlowFrame, in context: CGContext) {
        let pad = max(style.fontSize * 0.12, 4)
        let halo = frame.rect.insetBy(dx: -pad, dy: -pad * 0.5)
        let radius = min(halo.height / 2, pad * 1.6)
        context.saveGState()
        context.setAlpha(Glow.haloAlpha * frame.alpha)
        context.addPath(CGPath(roundedRect: halo, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        fillGradient(frame, in: context)
        context.restoreGState()
    }

    /// Fills the glyphs of the word with the gradient: the glyphs become the clip path.
    private func drawGradientGlyphs(_ frame: GlowFrame, origin: NSPoint, in context: CGContext) {
        context.saveGState()
        context.setAlpha(frame.alpha)
        context.setTextDrawingMode(.clip)
        layoutManager.drawGlyphs(forGlyphRange: frame.glyphRange, at: origin)
        fillGradient(frame, in: context)
        context.restoreGState()
    }

    /// The gradient band slides left to right across the word during the sweep.
    private func fillGradient(_ frame: GlowFrame, in context: CGContext) {
        let length = max(frame.rect.width, 40)
        let startX = frame.rect.minX + (frame.sweep - 0.5) * length
        context.drawLinearGradient(
            Glow.gradient,
            start: CGPoint(x: startX, y: frame.rect.midY),
            end: CGPoint(x: startX + length, y: frame.rect.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        syncContainerWidth()
        let theme = style.theme
        let width = bounds.width
        let height = bounds.height
        let readingY = height * min(max(style.readingLine, 0), 1)

        theme.background.setFill()
        bounds.fill()

        // Reading band.
        theme.band.setFill()
        NSRect(x: 0, y: readingY - lineHeight / 2, width: width, height: lineHeight).fill()

        // Text, drawn in container coordinates shifted so `offset` lands on the reading line.
        if textStorage.length > 0, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            if style.mirror {
                context.translateBy(x: width, y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let originY = ((readingY - offset) * scale).rounded() / scale
            let origin = NSPoint(x: (width - containerWidth) / 2, y: originY)
            let visibleRect = NSRect(x: 0, y: offset - readingY - 1, width: containerWidth, height: height + 2)
            let visible = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            if visible.length > 0 {
                let frames = glowFrames(visible: visible, origin: origin, now: animationClock())
                for frame in frames { drawHalo(frame, in: context) }
                layoutManager.drawBackground(forGlyphRange: visible, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: visible, at: origin)
                for frame in frames { drawGradientGlyphs(frame, origin: origin, in: context) }
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Fades. They stop short of the reading band so the current line stays clear.
        let background = theme.background
        let clear = background.withAlphaComponent(0)
        if let fade = NSGradient(starting: background, ending: clear) {
            let topHeight = max(0, min(height * 0.12, readingY - lineHeight / 2 - 4))
            let bottomHeight = max(0, min(height * 0.12, height - readingY - lineHeight / 2 - 4))
            if topHeight > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: 0, y: 0, width: width, height: topHeight).clip()
                fade.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: topHeight), options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
            if bottomHeight > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: 0, y: height - bottomHeight, width: width, height: bottomHeight).clip()
                fade.draw(from: NSPoint(x: 0, y: height), to: NSPoint(x: 0, y: height - bottomHeight), options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // Markers at both edges of the reading line.
        let size = max(10, min(18, style.fontSize * 0.28))
        let half = size * 0.75
        theme.marker.setFill()
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 0, y: readingY - half))
        left.line(to: NSPoint(x: size, y: readingY))
        left.line(to: NSPoint(x: 0, y: readingY + half))
        left.close()
        left.fill()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: width, y: readingY - half))
        right.line(to: NSPoint(x: width - size, y: readingY))
        right.line(to: NSPoint(x: width, y: readingY + half))
        right.close()
        right.fill()
    }

    // MARK: Manual scrolling

    override func scrollWheel(with event: NSEvent) {
        guard textStorage.length > 0 else { return }
        var delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if !event.hasPreciseScrollingDeltas { delta *= lineHeight }

        isUserScrolling = true
        resetLead()
        springRunning = false
        velocity = 0
        offset = min(max(offset - delta, 0), textHeight)
        target = offset
        lastScrollTime = CACurrentMediaTime()
        scheduleScrollTimer(after: Self.scrollSettleDelay)
        pauseLinkIfIdle()
        needsDisplay = true
    }

    private func scheduleScrollTimer(after delay: TimeInterval) {
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.scrollTimerFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func scrollTimerFired() {
        scrollTimer = nil
        let remaining = Self.scrollSettleDelay - (CACurrentMediaTime() - lastScrollTime)
        if remaining > 0.001 {
            scheduleScrollTimer(after: remaining)
            return
        }
        guard isUserScrolling else { return }
        commit(index: wordIndex(atContainerY: offset))
    }

    private func cancelUserScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        isUserScrolling = false
    }

    /// Sets the position the user chose, colors the text, animates to it and reports it.
    private func commit(index: Int) {
        cancelUserScroll()
        resetLead()
        let clamped = max(0, min(index, script.words.count))
        position = clamped
        applyColors()
        animate(to: targetOffset(for: clamped))
        onUserScroll?(clamped)
    }

    /// Index of the first word on the line at container y.
    private func wordIndex(atContainerY y: CGFloat) -> Int {
        guard textStorage.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: textContainer)
        return startIndex(ofLineWithGlyph: glyph).index
    }

    /// The word index at the start of the line that holds `glyph`, and the glyph range of that line.
    private func startIndex(ofLineWithGlyph glyph: Int) -> (index: Int, glyphs: NSRange) {
        var range = NSRange()
        layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
        let character = layoutManager.characterIndexForGlyph(at: range.location)
        return (script.wordIndex(atOrAfterCharacter: character), range)
    }

    // MARK: Keyboard and mouse

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.specialKey {
        case .upArrow?: moveLines(-1)
        case .downArrow?: moveLines(1)
        case .pageUp?: movePage(-1)
        case .pageDown?: movePage(1)
        case .home?: commit(index: 0)
        default:
            if event.charactersIgnoringModifiers == " " {
                if !event.isARepeat { onToggleListening?() }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Moves to the start of the previous or next line that holds a different word.
    private func moveLines(_ direction: Int) {
        guard textStorage.length > 0 else { return }
        let current = currentLine()
        var result = direction > 0 ? script.words.count : 0
        if direction > 0 {
            var next = NSMaxRange(current.glyphs)
            while next < layoutManager.numberOfGlyphs {
                let line = startIndex(ofLineWithGlyph: next)
                if line.index > current.index { result = line.index; break }
                next = NSMaxRange(line.glyphs)
            }
        } else {
            var previous = current.glyphs.location - 1
            while previous >= 0 {
                let line = startIndex(ofLineWithGlyph: previous)
                if line.index < current.index { result = line.index; break }
                previous = line.glyphs.location - 1
            }
        }
        commit(index: result)
    }

    /// Moves about 60 % of the view height. Blank and cue-only lines map to the next word,
    /// so the search continues in the move direction until the word index changes.
    private func movePage(_ direction: Int) {
        guard textStorage.length > 0 else { return }
        let current = currentLine()
        let y = min(max(restingTarget + CGFloat(direction) * bounds.height * 0.6, 0), textHeight)
        var line = startIndex(ofLineWithGlyph: layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: textContainer))
        let result: Int
        if direction > 0 {
            while line.index <= current.index, NSMaxRange(line.glyphs) < layoutManager.numberOfGlyphs {
                line = startIndex(ofLineWithGlyph: NSMaxRange(line.glyphs))
            }
            result = line.index <= current.index ? script.words.count : line.index
        } else {
            while line.index >= current.index, line.glyphs.location > 0 {
                line = startIndex(ofLineWithGlyph: line.glyphs.location - 1)
            }
            result = line.index >= current.index ? 0 : line.index
        }
        commit(index: result)
    }

    /// The y coordinate that keyboard navigation starts from: the center of the line that
    /// holds the current word. The moving target is not used, because it also holds the
    /// glide and the lead.
    private var restingTarget: CGFloat {
        guard !isUserScrolling else { return target }
        let character = startCharacter(forWordIndex: position)
        guard character >= 0, textStorage.length > 0 else { return 0 }
        return lineCenter(forGlyph: layoutManager.glyphIndexForCharacter(at: min(character, textStorage.length - 1)))
    }

    /// The line that holds the current word and the word index at its start. The glide
    /// puts the target between two lines, so the line comes from the word and not from y.
    private func currentLine() -> (index: Int, glyphs: NSRange) {
        let character = isUserScrolling ? -1 : startCharacter(forWordIndex: position)
        let glyph = character >= 0 && textStorage.length > 0
            ? layoutManager.glyphIndexForCharacter(at: min(character, textStorage.length - 1))
            : layoutManager.glyphIndex(for: NSPoint(x: 0, y: target), in: textContainer)
        return startIndex(ofLineWithGlyph: glyph)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}

/// Weak target for the display link. The link retains its target, so this keeps the view
/// from being retained by its own link.
private final class DisplayLinkProxy: NSObject {
    weak var view: PrompterTextView?

    @objc func tick(_ link: CADisplayLink) {
        view?.displayLinkFired(link)
    }
}
