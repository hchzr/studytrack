import Carbon.HIToolbox
import Foundation

/// ⌃⌥Espace, depuis n'importe quelle app : démarrer ou mettre en pause le
/// chrono sans quitter ce qu'on lit.
///
/// `RegisterEventHotKey` (Carbon) ne demande aucune autorisation
/// d'accessibilité, contrairement à une surveillance du clavier.
@MainActor
final class GlobalHotKey {
    /// L'inscription a échoué (le raccourci est pris — ⌃⌥Espace est aussi « source de
    /// saisie suivante » dans les réglages du clavier) : les Réglages le disent.
    static var lastRegistrationFailed = false
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        guard reference == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            // Chaque raccourci de l'app arrive à tous les gestionnaires : on ne
            // répond qu'au sien (« STRK »), sinon ⌘Tab d'étude lancerait le chrono.
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == OSType(0x5354524B) else { return OSStatus(eventNotHandledErr) }
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354524B), id: 1)  // « STRK »
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &reference)
        Self.lastRegistrationFailed = status != noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
