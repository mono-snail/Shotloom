import AppKit
import Carbon

enum HotKeyPreset: Int, CaseIterable, Identifiable {
    case commandShift2, controlOptionA, commandShiftD
    var id: Int { rawValue }
    var label: String {
        switch self { case .commandShift2: return "⌘ ⇧ 2"; case .controlOptionA: return "⌃ ⌥ A"; case .commandShiftD: return "⌘ ⇧ D" }
    }
    var keyCode: UInt32 {
        switch self { case .commandShift2: return UInt32(kVK_ANSI_2); case .controlOptionA: return UInt32(kVK_ANSI_A); case .commandShiftD: return UInt32(kVK_ANSI_D) }
    }
    var modifiers: UInt32 { self == .controlOptionA ? UInt32(controlKey | optionKey) : UInt32(cmdKey | shiftKey) }
}

struct HotKeyBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
    init(_ preset: HotKeyPreset) { keyCode = preset.keyCode; modifiers = preset.modifiers; label = preset.label }
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard flags.contains(.command) || flags.contains(.control), event.keyCode != 53,
              let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0) |
                    (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0)
        label = (flags.contains(.control) ? "⌃ " : "") + (flags.contains(.option) ? "⌥ " : "") +
                (flags.contains(.shift) ? "⇧ " : "") + (flags.contains(.command) ? "⌘ " : "") + key.uppercased()
    }
    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        return flags
    }
}

final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var binding: HotKeyBinding?
    private var keyIsDown = false
    private let identifier = UInt32.random(in: 1...UInt32.max)
    var onPress: (() -> Void)?
    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.id == owner.identifier, id.signature == 0x44435054 else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { owner.handleKeyEvent(pressed: pressed) }; return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let binding = self.binding else { return event }
            if NSApp.keyWindow?.firstResponder is ShortcutCaptureField { return event }
            guard UInt32(event.keyCode) == binding.keyCode else { return event }
            if event.type == .keyUp {
                self.handleKeyEvent(pressed: false)
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard flags == binding.flags else { return event }
            if !event.isARepeat { self.handleKeyEvent(pressed: true) }; return nil
        }
    }
    // Carbon and the local monitor can both report the same physical press.
    func handleKeyEvent(pressed: Bool) {
        guard pressed else { keyIsDown = false; return }
        guard !keyIsDown else { return }
        keyIsDown = true
        onPress?()
    }
    @discardableResult func register(_ preset: HotKeyPreset) -> Bool { register(HotKeyBinding(preset)) }
    @discardableResult func register(_ binding: HotKeyBinding) -> Bool {
        if self.binding == binding { return true }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x44435054, id: identifier)
        let result = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetEventDispatcherTarget(), 0, &next)
        guard result == noErr, handler != nil else { if let next { UnregisterEventHotKey(next) }; return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next; self.binding = binding; keyIsDown = false; return true
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; binding = nil; keyIsDown = false
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
