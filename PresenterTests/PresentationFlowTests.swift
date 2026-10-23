import Foundation
import PresenterCore
import Testing
@testable import Presenter

@MainActor
struct PresentationFlowTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func immediateSaveIncludesLatestTitleAndText() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore(directory: directory)
        let model = PrompterModel(store: store)
        model.setPresentationTitle("Last-minute title")
        model.setScriptText("The final edit before quitting.")
        #expect(model.flushSave())
        let reopened = PrompterModel(store: store)
        #expect(reopened.presentationTitle == "Last-minute title")
        #expect(reopened.scriptText == "The final edit before quitting.")
        #expect(!model.hasUnsavedChanges)
    }

    @Test func newAndSwitchingPreserveUnfinishedWork() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore(directory: directory)
        let model = PrompterModel(store: store)
        let firstID = model.currentPresentationID
        model.setScriptText("An unfinished first talk.")
        model.newPresentation()
        let secondID = model.currentPresentationID
        #expect(secondID != firstID)
        #expect(model.scriptText.isEmpty)
        model.setScriptText("A second talk.")
        model.openPresentation(firstID)
        #expect(model.scriptText == "An unfinished first talk.")
        let reopened = PrompterModel(store: store)
        #expect(reopened.currentPresentationID == firstID)
        reopened.openPresentation(secondID)
        #expect(reopened.scriptText == "A second talk.")
    }

    @Test func successfulImportCreatesSeparatePresentationAndResetsPrompting() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PrompterModel(store: PresentationStore(directory: directory))
        let firstID = model.currentPresentationID
        model.setScriptText("A previous presentation with words.")
        model.jump(to: 3)
        model.setMode(.prompt)
        let url = directory.appendingPathComponent("Imported talk.md")
        try "# Welcome\n\nHello **everyone**. [PAUSE]".write(to: url, atomically: true, encoding: .utf8)
        model.importPresentation(at: url)
        #expect(model.currentPresentationID != firstID)
        #expect(model.presentationTitle == "Imported talk")
        #expect(model.scriptText == "Welcome\n\nHello everyone. [PAUSE]")
        #expect(model.mode == .edit)
        #expect(model.position == 0)
        #expect(model.state == .idle)
        model.openPresentation(firstID)
        #expect(model.scriptText == "A previous presentation with words.")
    }

    @Test func failedImportLeavesCurrentPresentationIntact() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PrompterModel(store: PresentationStore(directory: directory))
        model.setScriptText("Keep my work.")
        let id = model.currentPresentationID
        model.setMode(.prompt)
        model.importPresentation(at: directory.appendingPathComponent("missing.docx"))
        #expect(model.currentPresentationID == id)
        #expect(model.scriptText == "Keep my work.")
        #expect(model.mode == .prompt)
        #expect(model.presentations.count == 1)
        #expect(model.fileError != nil)
    }

    @Test func failedSaveBlocksNavigationAndCanBeRetried() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore(directory: directory)
        let model = PrompterModel(store: store)
        let id = model.currentPresentationID
        // Replace the directory with a file to reproduce a real disk-write failure.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        model.setScriptText("Changes that must survive.")
        #expect(!model.flushSave())
        #expect(model.hasUnsavedChanges)
        model.newPresentation()
        #expect(model.currentPresentationID == id)
        #expect(model.scriptText == "Changes that must survive.")
        #expect(model.saveStatus == "Changes not saved")
        try FileManager.default.removeItem(at: directory)
        #expect(model.flushSave())
        #expect(try store.load(defaultText: "").current.text == "Changes that must survive.")
    }

    @Test func corruptLibraryIsNotOverwrittenByEditing() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore(directory: directory)
        let data = Data("corrupt library".utf8)
        try data.write(to: store.url)
        let model = PrompterModel(store: store)
        #expect(model.fileError != nil)
        #expect(model.saveStatus == "Saving unavailable")
        #expect(model.flushSave()) // No edits: quitting remains possible.
        model.setScriptText("New text")
        #expect(!model.flushSave())
        #expect(try Data(contentsOf: store.url) == data)
    }
}
