import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
import DictationEngine
@testable import Sunday_Voice

@MainActor
final class ClipboardTidyTests: XCTestCase {
    private var board: NSPasteboard!
    override func setUp() { board = NSPasteboard(name: .init("sunday-voice-tests-\(UUID().uuidString)")) }
    override func tearDown() { board.releaseGlobally() }

    private func tidy(_ reply: @escaping (String?) async throws -> TidyResult) -> (ClipboardTidy, HUD) {
        let hud = HUD()
        return (ClipboardTidy(hud: hud, board: board) { reply }, hud)
    }

    func testReplacesClipboardAndUndoRestoresEveryType() async {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("so um pls send teh deck", forType: .string)
        item.setData(Data("<b>rich</b>".utf8), forType: .html)
        board.writeObjects([item])
        let (t, hud) = tidy { _ in TidyResult(text: "Please send the deck.", changed: true) }
        t.run()
        XCTAssertEqual(hud.state, .tidying)
        await t.task?.value
        XCTAssertEqual(board.string(forType: .string), "Please send the deck.")
        XCTAssertEqual(hud.state, .tidied)
        t.undo()
        XCTAssertEqual(board.string(forType: .string), "so um pls send teh deck")
        XCTAssertEqual(board.data(forType: .html), Data("<b>rich</b>".utf8))
        XCTAssertEqual(hud.state, .tidyRestored)
        hud.show(.hidden)
    }

    func testUndoNeverOverwritesANewerCopy() async {
        board.clearContents(); board.setString("old", forType: .string)
        let (t, hud) = tidy { _ in TidyResult(text: "Old.", changed: true) }
        t.run(); await t.task?.value
        board.clearContents(); board.setString("something newer", forType: .string)
        t.undo()
        XCTAssertEqual(board.string(forType: .string), "something newer")
        hud.show(.hidden)
    }

    func testFailureLeavesTheOriginal() async {
        board.clearContents(); board.setString("call me at 604", forType: .string)
        let (t, hud) = tidy { _ in throw TidyError.unsafe }
        t.run(); await t.task?.value
        XCTAssertEqual(board.string(forType: .string), "call me at 604")
        XCTAssertEqual(hud.state, .error(L("tidy.error.unsafe"), .close))
        hud.show(.hidden)
    }

    func testFailuresSayWhyAndBusyPressStillShowsThePill() async {
        board.clearContents(); board.setString("hello there", forType: .string)
        let (t, hud) = tidy { _ in throw TidyError.failed("timeout") }
        t.run(); await t.task?.value
        XCTAssertEqual(hud.state, .error(L("tidy.error.failedReason", L("tidy.reason.timeout")), .close))
        XCTAssertEqual(ClipboardTidy.message(TidyError.failed("network_-1009")), L("tidy.error.failedReason", L("tidy.reason.network")))
        XCTAssertEqual(ClipboardTidy.message(TidyError.failed("http_502")), L("tidy.error.failedReason", L("tidy.reason.server")))
        var release: CheckedContinuation<Void, Never>?
        let (slow, slowHud) = tidy { _ in await withCheckedContinuation { release = $0 }; return TidyResult(text: "Hello.", changed: true) }
        slow.run()
        slowHud.show(.hidden)
        slow.run() // pressed again while working
        XCTAssertEqual(slowHud.state, .tidying)
        while release == nil { await Task.yield() }
        release?.resume(); await slow.task?.value
        XCTAssertTrue(HUDState.tidying.isTidy && HUDState.tidied.isTidy && !HUDState.hidden.isTidy)
        hud.show(.hidden); slowHud.show(.hidden)
    }

    func testCopyDuringTheRequestWins() async {
        board.clearContents(); board.setString("first", forType: .string)
        let b = board!
        let (t, hud) = tidy { _ in
            await MainActor.run { b.clearContents(); b.setString("copied meanwhile", forType: .string) }
            return TidyResult(text: "First.", changed: true)
        }
        t.run(); await t.task?.value
        XCTAssertEqual(board.string(forType: .string), "copied meanwhile")
        XCTAssertEqual(hud.state, .error(L("tidy.error.changed"), .close))
        hud.show(.hidden)
    }

    func testEmptyFilesAndSignedOutAreFriendlyNoOps() async {
        var called = false
        let (t, hud) = tidy { _ in called = true; return TidyResult(text: "x", changed: true) }
        board.clearContents(); board.setString("   ", forType: .string)
        t.run(); await t.task?.value
        XCTAssertEqual(hud.state, .error(L("tidy.error.empty"), .close))
        board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertNil(ClipboardTidy.copiedText(board))
        t.run(); await t.task?.value
        XCTAssertEqual(hud.state, .error(L("tidy.error.empty"), .close))
        XCTAssertFalse(called)
        let signedOut = ClipboardTidy(hud: hud, board: board) { nil }
        board.clearContents(); board.setString("hello", forType: .string)
        signedOut.run()
        XCTAssertEqual(hud.state, .error(L("tidy.error.signIn"), .close))
        XCTAssertEqual(board.string(forType: .string), "hello")
        hud.show(.hidden)
    }

    func testAlreadyTidyKeepsTheClipboard() async {
        board.clearContents(); board.setString("Looks good.", forType: .string)
        let before = board.changeCount
        let (t, hud) = tidy { _ in TidyResult(text: "Looks good.", changed: false) }
        t.run(); await t.task?.value
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(hud.state, .tidyUnchanged)
        hud.show(.hidden)
    }

    func testSelectionWinsOverClipboardAndUnchangedSelectionIsCopied() async {
        board.clearContents(); board.setString("unrelated clipboard", forType: .string)
        let (t, hud) = tidy { raw in
            XCTAssertEqual(raw, "Looks good.")
            return TidyResult(text: "Looks good.", changed: false)
        }
        t.readSelection = { "Looks good." }
        t.run(); await t.task?.value
        XCTAssertEqual(board.string(forType: .string), "Looks good.")
        XCTAssertEqual(hud.state, .tidied)
        t.undo()
        XCTAssertEqual(board.string(forType: .string), "unrelated clipboard")
        hud.show(.hidden)
    }

    func testNoSelectionUsesClipboardAndSelectionFailureDoesNotSendIt() async {
        board.clearContents(); board.setString("copy fallback", forType: .string)
        var calls = 0
        let (t, hud) = tidy { raw in
            calls += 1; XCTAssertEqual(raw, "copy fallback")
            return TidyResult(text: "Copy fallback.", changed: true)
        }
        t.readSelection = { nil }
        t.run(); await t.task?.value
        XCTAssertEqual(board.string(forType: .string), "Copy fallback.")
        t.readSelection = { throw SelectedTextReader.Failure.permission }
        t.run(); await t.task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(hud.state, .error(L("tidy.error.permission"), .accessibilitySettings))
        XCTAssertEqual(board.string(forType: .string), "Copy fallback.")
        hud.show(.hidden)
    }

    func testShortcutDefaultsDisplayAndConflicts() {
        XCTAssertEqual(TidyShortcut.default.modifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(TidyShortcut.default.cocoaModifiers, [.control, .option])
        XCTAssertTrue(TidyShortcut.default.display.hasPrefix("⌃⌥"))
        XCTAssertFalse(TidyShortcut.default.conflicts(with: Prefs.defaultTriggers))
        XCTAssertEqual(TidyShortcut(trigger: TidyShortcut.default.trigger), .default)
        XCTAssertNil(TidyShortcut(trigger: .mouseButton(number: 4, mode: .bilingual)))
        XCTAssertTrue(TidyShortcut.copyLatest.conflicts(with: []))
        let f18 = TidyShortcut(keyCode: 79, modifiers: 0)
        XCTAssertTrue(f18.conflicts(with: [.key(keyCode: 79, modifiers: 0, mode: .english)]))
        XCTAssertEqual(f18.display, "F18")
        let shiftOnly = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "T", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: UInt16(kVK_ANSI_T))!
        XCTAssertNil(TidyShortcut(event: shiftOnly))
        let ctrlOpt = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: UInt16(kVK_ANSI_T))!
        XCTAssertEqual(TidyShortcut(event: ctrlOpt), .default)
    }

    func testPrefsListMigratesFromTheSingle0216Key() {
        let defaults = UserDefaults.standard
        let keys = ["tidyShortcuts", "tidyShortcut", "tidyShortcutOff"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { defaults.set(v, forKey: k) } }
        keys.forEach(defaults.removeObject(forKey:))
        XCTAssertEqual(Prefs.tidyShortcuts, [.default])
        let custom = TidyShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey | shiftKey))
        defaults.set(try? JSONEncoder().encode(custom), forKey: "tidyShortcut")
        XCTAssertEqual(Prefs.tidyShortcuts, [custom])
        defaults.set(true, forKey: "tidyShortcutOff")
        XCTAssertEqual(Prefs.tidyShortcuts, [])
        Prefs.tidyShortcuts = [.default, custom]
        XCTAssertEqual(Prefs.tidyShortcuts, [.default, custom])
        Prefs.tidyShortcuts = []
        XCTAssertEqual(Prefs.tidyShortcuts, [])
    }

    func testTidyKeyCaptureRules() {
        let f18 = TriggerKind.key(keyCode: 79, modifiers: 0, mode: .english)
        let ctrlOptY = TriggerKind.key(keyCode: UInt16(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey), mode: .bilingual)
        // Allowed: a fresh combo; a bare F-key no dictation card uses.
        XCTAssertNil(OnboardingModel.tidyProblem(ctrlOptY, tidyKeys: [.default], triggers: []))
        XCTAssertNil(OnboardingModel.tidyProblem(f18, tidyKeys: [.default], triggers: []))
        // Refused: mouse buttons and holds, bare letters / ⇧+letter, duplicates, ⌃⌥V, a dictation key.
        XCTAssertEqual(OnboardingModel.tidyProblem(.mouseButton(number: 4, mode: .bilingual), tidyKeys: [], triggers: []), L("ob.keys.tidyKeysOnly"))
        XCTAssertEqual(OnboardingModel.tidyProblem(.modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180), tidyKeys: [], triggers: []), L("ob.keys.tidyKeysOnly"))
        XCTAssertEqual(OnboardingModel.tidyProblem(.key(keyCode: UInt16(kVK_ANSI_T), modifiers: 0, mode: .bilingual), tidyKeys: [], triggers: []), L("settings.tidy.needsModifier"))
        XCTAssertEqual(OnboardingModel.tidyProblem(.key(keyCode: UInt16(kVK_ANSI_T), modifiers: UInt32(shiftKey), mode: .bilingual), tidyKeys: [], triggers: []), L("settings.tidy.needsModifier"))
        XCTAssertNotNil(OnboardingModel.tidyProblem(TidyShortcut.default.trigger, tidyKeys: [.default], triggers: []))
        XCTAssertEqual(OnboardingModel.tidyProblem(TidyShortcut.copyLatest.trigger, tidyKeys: [], triggers: []), L("settings.tidy.conflict"))
        XCTAssertEqual(OnboardingModel.tidyProblem(f18, tidyKeys: [], triggers: [f18]), L("ob.keys.usedForDictation", "F18"))
    }

    func testTidyPillsFitAndRenderInBothLanguages() throws {
        Theme.registerFonts()
        let original = UILanguage.choice
        defer { UILanguage.choice = original }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sunday-voice-tidy-pills")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for (name, state) in [("tidying", HUDState.tidying), ("tidied", .tidied), ("unchanged", .tidyUnchanged), ("restored", .tidyRestored),
                                  ("empty", .error(L("tidy.error.empty"), .close)), ("unsafe", .error(L("tidy.error.unsafe"), .close))] {
                for dark in [false, true] {
                    let rep = try XCTUnwrap(HUD.snapshot(state, dark: dark))
                    XCTAssertLessThan(rep.size.width, 560, "\(name) \(language) pill too wide")
                    try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testKeysStepShowsTheTidyCardInBothLanguages() throws {
        Theme.registerFonts()
        let original = UILanguage.choice
        defer { UILanguage.choice = original }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sunday-voice-tidy-card")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let auth = AuthService()
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for dark in [false, true] {
                let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
                model.triggers = [.controlHold(mode: .bilingual, holdMilliseconds: 180), .mouseButton(number: 4, mode: .bilingual), .key(keyCode: 79, modifiers: 0, mode: .english)]
                model.tidyKeys = [.default]
                let view = KeysStep(model: model).padding(32).frame(width: 620).background(Theme.ground(dark ? .dark : .light))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("keys-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
