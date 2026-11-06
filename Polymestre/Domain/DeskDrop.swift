import CryptoKit
import Foundation

/// Ce que l'iPhone envoie au bureau du Mac pendant une session : la photo de
/// ta copie, un « je bloque » (la photo, et Claude cherche l'indice), une
/// question dictée. Par le lien du chrono, chiffré de la même clé ; rien
/// n'est gardé par le relais.
///
/// Pur, testé dans `validate.sh`.
struct DeskDrop: Codable, Equatable, Identifiable {
    enum Intent: String, Codable {
        /// Ta copie : jointe à la conversation, à envoyer quand tu veux.
        case copy
        /// Tu bloques : la photo part à Claude, qui donne l'indice minimal.
        case stuck
        /// Une question (tapée ou dictée), envoyée telle quelle.
        case ask
    }

    var id = UUID()
    var from: String
    var intent: Intent
    /// Un PDF (une numérisation) ou une image JPEG.
    var document: Data?
    var isPDF = false
    var question: String?
    /// L'exercice que l'iPhone avait sous les yeux.
    var exerciseID: UUID?
    var sentAt: Date

    /// Le relais refuse au-delà (un message WebSocket < 1 Mo, chiffré et en base64).
    static let maxDocumentBytes = 640_000

    static func seal(_ drop: DeskDrop, key: SymmetricKey) -> String? {
        guard (drop.document?.count ?? 0) <= maxDocumentBytes,
              let data = try? JSONEncoder().encode(drop),
              let box = try? AES.GCM.seal(data, using: key), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    static func open(_ text: String, key: SymmetricKey) -> DeskDrop? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(DeskDrop.self, from: plain)
    }
}
