import Foundation
import SwiftData

/// Le chrono d'un appareil, tel qu'il le publie **par la base** iCloud.
///
/// Le magasin clé-valeur (`CloudRelay`) part quand iOS le décide — jusqu'à une
/// minute. La base, elle, est envoyée dans la seconde et poussée aux autres
/// appareils : un chrono démarré sur l'iPhone apparaît sur le Mac en quelques
/// secondes. Une balise par appareil (pas d'écriture concurrente sur la même
/// fiche) ; la plus récente des autres appareils fait foi.
@Model
final class RelayBeacon {
    var device: String = ""
    var updatedAt: Date = Date.now
    /// `CloudRelay.TimerSnapshot`, encodé.
    var payload: Data?

    init(device: String, updatedAt: Date = Date(), payload: Data? = nil) {
        self.device = device
        self.updatedAt = updatedAt
        self.payload = payload
    }
}
