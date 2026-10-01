import Foundation

/// Une trame zstd **sans compression** (blocs « bruts », RFC 8878 §3.1.1).
///
/// Le format récent du protocole d'AnkiWeb exige un corps zstd. Il ne sert à
/// l'app que pour découvrir le serveur du compte (`AnkiWebClient.discoverServer`)
/// et iOS n'a pas de zstd : une trame valide se compose sans compresser —
/// en-tête de trame, puis des blocs bruts de 128 Kio au plus.
enum ZstdFrame {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    static let maxBlock = 128 * 1024

    static func stored(_ data: Data) -> Data {
        var out = Data(magic)
        // Descripteur : Single_Segment = 1 (pas de fenêtre), taille du contenu
        // sur 4 octets (Frame_Content_Size_flag = 2), pas de somme de contrôle.
        out.append(0b1010_0000)
        var size = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let length = min(maxBlock, bytes.count - offset)
            let isLast = offset + length >= bytes.count
            // En-tête de bloc (3 octets) : dernier bloc, type 0 (brut), taille.
            let header = UInt32(length) << 3 | (isLast ? 1 : 0)
            out.append(UInt8(header & 0xFF))
            out.append(UInt8((header >> 8) & 0xFF))
            out.append(UInt8((header >> 16) & 0xFF))
            out.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        } while offset < bytes.count
        return out
    }
}
