import AppKit
import Foundation

public enum ScriptImporter {
    public static func read(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return try markdownText(readText(url))
        case "txt":
            return try readText(url)
        case "rtf":
            return try documentText(url, type: .rtf)
        case "docx":
            return try documentText(url, type: .officeOpenXML)
        default:
            throw ImportError.unsupportedType
        }
    }

    public static func markdownText(_ source: String) throws -> String {
        let parsed = try AttributedString(markdown: source)
        var blocks: [String] = []
        var block = ""
        var previousIdentity: Int?
        for run in parsed.runs {
            let identity = run.presentationIntent?.components.first?.identity
            if identity != previousIdentity, !block.isEmpty {
                blocks.append(block.trimmingCharacters(in: .newlines))
                block = ""
            }
            block += String(parsed[run.range].characters)
            previousIdentity = identity
        }
        if !block.isEmpty { blocks.append(block.trimmingCharacters(in: .newlines)) }
        return blocks.joined(separator: "\n\n")
    }

    private static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    private static func documentText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        // Pin the reader: a renamed HTML file must not be rendered or load remote resources.
        try NSAttributedString(
            url: url, options: [.documentType: type], documentAttributes: nil).string
    }

    public enum ImportError: LocalizedError {
        case unsupportedType
        public var errorDescription: String? {
            "Choose a plain text, Markdown, RTF, or DOCX file."
        }
    }
}
