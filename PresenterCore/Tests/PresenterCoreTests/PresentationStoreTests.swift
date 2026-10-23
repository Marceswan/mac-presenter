import Foundation
import Testing
@testable import PresenterCore

struct PresentationStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savesIndependentPresentationsAndRestoresSelection() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore(directory: directory)
        var workspace = try store.load(defaultText: "Welcome")
        let firstID = workspace.selectedID
        workspace.renameCurrent(to: "First talk")
        workspace.setText("Hello [PAUSE] everyone.\n\nCafé ☕️")
        workspace.add(title: "Second talk", text: "Another presentation")
        let secondID = workspace.selectedID
        try store.save(workspace)

        var reopened = try store.load(defaultText: "Should not replace saved content")
        #expect(reopened.selectedID == secondID)
        #expect(reopened.current.text == "Another presentation")
        reopened.select(firstID)
        #expect(reopened.current.title == "First talk")
        #expect(reopened.current.text == "Hello [PAUSE] everyone.\n\nCafé ☕️")
        reopened.setText("An edited first talk")
        try store.save(reopened)
        let final = try store.load(defaultText: "")
        #expect(final.presentations.count == 2)
        #expect(final.current.text == "An edited first talk")
        #expect(final.presentations.first { $0.id == secondID }?.text == "Another presentation")
    }

    @Test func migratesLegacyScriptWithoutRemovingIt() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("script.txt")
        try "My existing script".write(to: legacy, atomically: true, encoding: .utf8)
        let store = PresentationStore(directory: directory)
        let workspace = try store.load(defaultText: "Sample")
        #expect(workspace.current.text == "My existing script")
        try store.save(workspace)
        try "Changed old file".write(to: legacy, atomically: true, encoding: .utf8)
        #expect(try store.load(defaultText: "Sample").current.text == "My existing script")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func corruptLibraryIsReportedAndPreserved() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presentations.json")
        let corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) {
            try PresentationStore(directory: directory).load(defaultText: "Sample")
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func rejectsInvalidWorkspaceAndFutureVersions() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presentations.json")
        let store = PresentationStore(directory: directory)
        let workspace = PresentationWorkspace(title: "First", text: "Text")
        let data = try JSONEncoder().encode(workspace)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("version", 999 as Any), ("presentations", [] as Any), ("selectedID", UUID().uuidString as Any)] {
            var invalid = json
            invalid[key] = value
            try JSONSerialization.data(withJSONObject: invalid).write(to: url)
            #expect(throws: (any Error).self) { try store.load(defaultText: "Sample") }
        }
        let entries = try #require(json["presentations"] as? [Any])
        json["presentations"] = entries + entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(throws: (any Error).self) { try store.load(defaultText: "Sample") }
    }

    @Test func newPresentationPreservesPreviousTextAndNormalizesTitle() {
        var workspace = PresentationWorkspace(title: "Original", text: "Unfinished work")
        let originalID = workspace.selectedID
        workspace.add(title: "  \n ", text: "")
        #expect(workspace.current.title == "Untitled Presentation")
        #expect(workspace.current.id != originalID)
        workspace.select(originalID)
        #expect(workspace.current.text == "Unfinished work")
        workspace.renameCurrent(to: "  Renamed talk \n")
        #expect(workspace.current.title == "Renamed talk")
        workspace.select(UUID())
        #expect(workspace.selectedID == originalID)
    }

    @Test func saveFailureIsReported() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        #expect(throws: (any Error).self) {
            try PresentationStore(directory: blockingFile).save(PresentationWorkspace(title: "Talk", text: "Text"))
        }
    }
}
