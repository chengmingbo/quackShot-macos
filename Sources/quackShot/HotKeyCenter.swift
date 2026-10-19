import AppKit
import Carbon.HIToolbox
import QuackShotCore

/// The global capture shortcut, registered with Carbon's
/// `RegisterEventHotKey`. Unlike a CGEventTap this needs no Accessibility
/// or Input Monitoring permission, which keeps onboarding to one prompt.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private static let signature: OSType = 0x7175_636B // 'quck'
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// Why the last registration failed, in words fit for a menu item.
    private(set) var failure: String?
    private(set) var registered: HotKey?

    func install(_ key: HotKey, onFire: @escaping () -> Void) {
        self.onFire = onFire
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                if id.signature == HotKeyCenter.signature {
                    DispatchQueue.main.async { HotKeyCenter.shared.onFire?() }
                }
                return noErr
            }, 1, &spec, nil, &handlerRef)
            if status != noErr {
                failure = "Could not install the hot key handler (OSStatus \(status))."
                return
            }
        }
        register(key)
    }

    func register(_ key: HotKey) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
        guard key.hasModifier else {
            failure = "\(key.display) needs ⌘, ⌥ or ⌃ to work as a global shortcut."
            return
        }
        var mods: UInt32 = 0
        if key.command { mods |= UInt32(cmdKey) }
        if key.option { mods |= UInt32(optionKey) }
        if key.shift { mods |= UInt32(shiftKey) }
        if key.control { mods |= UInt32(controlKey) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, mods, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registered = key
            failure = nil
        } else if status == eventHotKeyExistsErr {
            failure = "\(key.display) is taken by another app. Choose another shortcut in Settings."
        } else {
            failure = "\(key.display) could not be registered (OSStatus \(status))."
        }
    }
}
