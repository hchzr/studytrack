import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Génère un QR code à partir d'une chaîne, sans dépendance externe.
///
/// CoreImage sait le faire depuis iOS 7 : importer une bibliothèque tierce pour
/// afficher un carré noir et blanc serait disproportionné.
enum QRCodeRenderer {

    /// Rendu d'un QR code, ou `nil` si la chaîne est vide ou le filtre indisponible.
    ///
    /// - Parameter correctionLevel: `L`, `M`, `Q` ou `H`. `M` (~15 %) tolère une
    ///   photo floue prise à travers une table de bibliothèque, ce qui est le cas
    ///   d'usage réel.
    static func image(from string: String,
                      correctionLevel: String = "M",
                      scale: CGFloat = 10) -> UIImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Un contexte par appel : partagé et mis en cache, `CIContext` garde des
        // ressources GPU alors que cette génération est rare et ponctuelle.
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
