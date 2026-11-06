import XCTest
import AppKit
@testable import DeskCapture

final class SettingsTests: XCTestCase {
    @MainActor
    func testToolbarVisibilityAndOrderPersistIncludingEmptyLayout() throws {
        let name = "DeskCapture.SettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ToolbarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.displayed, CaptureToolbarItem.defaults)
        preferences.setVisible(.magnify, true)
        preferences.setVisible(.pen, false)
        preferences.move(.magnify, by: -1)
        let restored = ToolbarPreferences(defaults: defaults)
        XCTAssertEqual(restored.displayed, preferences.displayed)
        XCTAssertFalse(restored.editorTools.contains(.pen))
        XCTAssertTrue(restored.editorTools.contains(.magnify))
        for item in restored.order { restored.setVisible(item, false) }
        XCTAssertEqual(ToolbarPreferences(defaults: defaults).displayed, [])
        XCTAssertEqual(restored.hidden.count, CaptureToolbarItem.allCases.count)
        restored.reset()
        XCTAssertEqual(ToolbarPreferences(defaults: defaults).displayed, CaptureToolbarItem.defaults)
    }
    @MainActor
    func testToolbarRepairsUnknownAndDuplicateStoredItems() throws {
        let name = "DeskCapture.SettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["text", "removed", "text", "save"], forKey: "captureToolbarOrder")
        let preferences = ToolbarPreferences(defaults: defaults)
        XCTAssertEqual(Array(preferences.order.prefix(2)), [.text, .save])
        XCTAssertEqual(Set(preferences.order).count, CaptureToolbarItem.allCases.count)
        XCTAssertEqual(preferences.order.count, CaptureToolbarItem.allCases.count)
    }
    @MainActor
    func testClearingPrimaryAndModeShortcutsPersistsAcrossRestart() throws {
        let defaults = AppPreferences.standard
        let keys = ["primaryShortcutEnabled", "customHotKey", "modeHotKeys", "hotKeyPreset"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "primaryShortcutEnabled")
        defaults.removeObject(forKey: "modeHotKeys")
        let app = AppCoordinator()
        app.customBinding = HotKeyBinding(.commandShiftD)
        app.primaryShortcutEnabled = true
        app.clearPrimaryShortcut()
        XCTAssertFalse(app.primaryShortcutEnabled)
        XCTAssertNil(app.customBinding)
        XCTAssertEqual(app.shortcutLabel, L10n.text("未设置"))
        XCTAssertNil(defaults.data(forKey: "customHotKey"))
        app.modeBindings[CaptureMode.window.rawValue] = HotKeyBinding(.controlOptionA)
        app.setModeShortcut(.window, binding: nil, notify: false)
        XCTAssertNil(app.modeBindings[CaptureMode.window.rawValue])
        let restarted = AppCoordinator()
        XCTAssertFalse(restarted.primaryShortcutEnabled)
        XCTAssertEqual(restarted.shortcutLabel, L10n.text("未设置"))
        XCTAssertNil(restarted.modeBindings[CaptureMode.window.rawValue])
    }
    @MainActor
    func testShortcutCaptureInterceptsMenuEquivalentAndEscapeCancels() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = ShortcutCaptureField(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        field.isEditable = false; field.savedLabel = "未设置"; window.contentView?.addSubview(field)
        var captured: HotKeyBinding?
        field.onBinding = { captured = $0 }
        window.makeFirstResponder(field)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
        XCTAssertTrue(field.performKeyEquivalent(with: event))
        XCTAssertEqual(captured?.keyCode, 1)
        captured = nil
        window.makeFirstResponder(field)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        field.keyDown(with: escape)
        XCTAssertNil(captured)
        XCTAssertEqual(field.stringValue, "未设置")
        XCTAssertFalse(window.firstResponder === field)
        window.close()
    }
}
