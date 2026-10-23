import Foundation

public struct Presentation: Codable, Identifiable, Equatable {
    public let id: UUID
    public fileprivate(set) var title: String
    public fileprivate(set) var text: String
    public fileprivate(set) var updatedAt: Date
}

/// Every presentation, including unfinished work, has its own stable identity.
public struct PresentationWorkspace: Codable, Equatable {
    private var version = 1
    public private(set) var presentations: [Presentation]
    public private(set) var selectedID: UUID

    public init(title: String, text: String) {
        let presentation = Presentation(id: UUID(), title: Self.title(title), text: text, updatedAt: Date())
        presentations = [presentation]
        selectedID = presentation.id
    }

    // Initialization, decoding validation and mutations maintain this invariant.
    public var current: Presentation { presentations.first { $0.id == selectedID }! }

    public mutating func setText(_ text: String) {
        guard let index = presentations.firstIndex(where: { $0.id == selectedID }),
              presentations[index].text != text else { return }
        presentations[index].text = text
        presentations[index].updatedAt = Date()
    }

    public mutating func renameCurrent(to title: String) {
        guard let index = presentations.firstIndex(where: { $0.id == selectedID }) else { return }
        let title = Self.title(title)
        guard presentations[index].title != title else { return }
        presentations[index].title = title
        presentations[index].updatedAt = Date()
    }

    public mutating func add(title: String, text: String) {
        let presentation = Presentation(id: UUID(), title: Self.title(title), text: text, updatedAt: Date())
        presentations.append(presentation)
        selectedID = presentation.id
    }

    public mutating func select(_ id: UUID) {
        guard presentations.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    fileprivate func validate() throws {
        guard version == 1 else { throw PresentationStoreError.unsupportedVersion }
        guard !presentations.isEmpty,
              Set(presentations.map(\.id)).count == presentations.count,
              presentations.contains(where: { $0.id == selectedID }) else {
            throw PresentationStoreError.invalidWorkspace
        }
    }

    private static func title(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Presentation" : trimmed
    }
}

public enum PresentationStoreError: LocalizedError {
    case unsupportedVersion
    case invalidWorkspace

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This presentation library was saved by an unsupported version of Presenter."
        case .invalidWorkspace: "The presentation library is damaged."
        }
    }
}

public struct PresentationStore {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("presentations.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport() throws -> PresentationStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return PresentationStore(directory: directory.appendingPathComponent("Presenter", isDirectory: true))
    }

    public func load(defaultText: String) throws -> PresentationWorkspace {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            // Migrate only when the library is absent. Keep the old file for recovery.
            let legacy = directory.appendingPathComponent("script.txt")
            do {
                let text = try String(contentsOf: legacy, encoding: .utf8)
                return PresentationWorkspace(title: "Recovered Script", text: text)
            } catch CocoaError.fileReadNoSuchFile {
                return PresentationWorkspace(title: "Welcome to Presenter", text: defaultText)
            }
        }
        let workspace = try JSONDecoder().decode(PresentationWorkspace.self, from: data)
        try workspace.validate()
        return workspace
    }

    public func save(_ workspace: PresentationWorkspace) throws {
        try workspace.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
