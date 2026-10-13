import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Rend les pages d'un PDF en JPEG, pour le modèle qui **voit** les pages et pour
/// l'aperçu de la relecture.
///
/// Le texte d'un polycopié LaTeX perd ses symboles (« ≤ » devient rien), éclate
/// ses fractions et mélange ses colonnes : les sous-questions en sortaient fausses.
/// L'image garde la structure telle qu'on la lit.
enum PDFPageRenderer {

    /// Largeur de rendu : assez pour lire un indice, assez peu pour tenir dans
    /// une requête (≈ 150 dpi sur une page A4).
    static let targetWidth: CGFloat = 1240
    static let jpegQuality: CGFloat = 0.6
    /// Au-delà, le PDF n'est pas une série : un polycopié entier, qu'on ne rend pas.
    static let maxPages = 20

    static func jpegPages(of document: PDFDocument) -> [Data] {
        var result: [Data] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0 else { continue }
            let scale = targetWidth / bounds.width
            let size = CGSize(width: targetWidth, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let data = jpeg(image) { result.append(data) }
        }
        return result
    }

    #if canImport(UIKit)
    private static func jpeg(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }
    #elseif canImport(AppKit)
    private static func jpeg(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
    #endif
}
