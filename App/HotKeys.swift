import Carbon.HIToolbox

/// System-wide hotkeys that work while Zoom is in front. Uses the Carbon
/// hotkey API, which doesn't need Accessibility permission.
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// ⌃⌥ + key
    func register(keyCode: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A4D_4954), id: id) // 'ZMIT'
        RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
    }

    deinit {
        refs.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        if let handler { RemoveEventHandler(handler) }
    }
}
