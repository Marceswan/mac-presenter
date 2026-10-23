import AppKit
import Foundation
import Testing
@testable import PresenterCore

struct ScriptImportTests {
    @Test func markdownKeepsReadableBlocksAndCues() throws {
        let source = """
        # Opening

        Hello **everyone**. [PAUSE] Read *slowly*.

        - First point
        - Second [point](https://example.com)

        > Closing thought
        """
        let text = try ScriptImporter.markdownText(source)
        #expect(text == "Opening\n\nHello everyone. [PAUSE] Read slowly.\n\nFirst point\n\nSecond point\n\nClosing thought")
        #expect(Script(text: text).cueRanges.count == 1)
    }

    @Test func markdownPreservesCodeAndLineBreaks() throws {
        let source = "First  \nSecond\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nFinal"
        let text = try ScriptImporter.markdownText(source)
        #expect(text == "First\nSecond\n\nlet x = 1\nlet y = 2\n\nFinal")
    }

    @Test func markdownKeepsNestedListsTableCellsAndReferenceLinkLabels() throws {
        let source = "# Talk\n\n- Parent\n  - Child\n\n[Read this][ref] [PAUSE]\n\n[ref]: https://example.com\n\n| One | Two |\n| --- | --- |\n| A | B |"
        let text = try ScriptImporter.markdownText(source)
        #expect(text == "Talk\n\nParent\n\nChild\n\nRead this [PAUSE]\n\nOne\n\nTwo\n\nA\n\nB")
        #expect(Script(text: text).words.map(\.key).contains("read"))
        #expect(!Script(text: text).words.map(\.key).contains("pause"))
    }

    @Test func importsIndependentOOXMLFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "presentation", withExtension: "docx", subdirectory: "Fixtures"))
        let text = try ScriptImporter.read(url)
        #expect(text.contains("Hello Café. [PAUSE]"))
        #expect(text.contains("Second paragraph."))
        #expect(text.contains("Left cell"))
        #expect(text.contains("Right cell"))
        #expect(Script(text: text).cueRanges.count == 1)
    }

    @Test func importsSupportedFilesWithoutModifyingSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["md", "markdown", "MD"] {
            let url = directory.appendingPathComponent("Talk.\(ext)")
            try "# Title\n\n**Hello** [PAUSE]".write(to: url, atomically: true, encoding: .utf8)
            #expect(try ScriptImporter.read(url) == "Title\n\nHello [PAUSE]")
            #expect(try String(contentsOf: url, encoding: .utf8) == "# Title\n\n**Hello** [PAUSE]")
        }
        let plain = directory.appendingPathComponent("Talk.txt")
        try "Hello **literal** [PAUSE]".write(to: plain, atomically: true, encoding: .utf16)
        #expect(try ScriptImporter.read(plain) == "Hello **literal** [PAUSE]")
    }

    @Test func importsRealDOCXAndRTFText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Hello Café. [PAUSE]\n\nAnother paragraph."
        let attributed = NSAttributedString(string: source)
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("rtf", .rtf)] {
            let url = directory.appendingPathComponent("Talk.\(ext)")
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type])
            try data.write(to: url)
            let text = try ScriptImporter.read(url)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == source)
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func reportsUnreadableAndUnsupportedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try ScriptImporter.read(directory.appendingPathComponent("missing.txt")) }
        let url = directory.appendingPathComponent("broken.docx")
        try Data("not a word document".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ScriptImporter.read(url) }
        let unsupported = directory.appendingPathComponent("page.html")
        try Data("<h1>Title</h1>".utf8).write(to: unsupported)
        #expect(throws: (any Error).self) { try ScriptImporter.read(unsupported) }
        for ext in ["docx", "rtf"] {
            let disguised = directory.appendingPathComponent("disguised.\(ext)")
            try Data("<html><body><img src='https://example.com/image.png'>Hidden HTML</body></html>".utf8).write(to: disguised)
            #expect(throws: (any Error).self) { try ScriptImporter.read(disguised) }
        }
    }
}
