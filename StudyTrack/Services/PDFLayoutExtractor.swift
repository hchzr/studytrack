import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#else
// Compilé aussi pour macOS par `validate.sh`, qui passe de vrais PDF générés
// dans l'extracteur : c'est la seule façon de tester la lecture de la mise en page.
import AppKit
typealias PlatformFont = NSFont
#endif

/// Lit un PDF en **conservant sa mise en page**.
///
/// `PDFPage.string` aplatit tout : les titres et les énoncés deviennent un seul
/// flux, et plus rien ne les distingue. C'est la cause directe des faux intitulés
/// (« solution générale. » sous l'exercice 1). `selectionsByLine()` garde les
/// lignes, et la chaîne attribuée porte la police — donc la taille.
enum PDFLayoutExtractor {

    /// Une ligne par ligne du document, avec sa taille de police dominante.
    ///
    /// Une page sans texte (scan) ne produit rien : c'est ce que l'écran annonce
    /// comme « aucun texte lisible » plutôt que d'inventer une structure.
    static func lines(from document: PDFDocument) -> [PDFLayoutLine] {
        var result: [PDFLayoutLine] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            result.append(contentsOf: lines(from: page, pageIndex: pageIndex))
        }
        return result
    }

    static func lines(from page: PDFPage, pageIndex: Int = 0) -> [PDFLayoutLine] {
        let bounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: bounds) else {
            // Repli : le texte de la page, ligne par ligne, sans information de police.
            let raw = page.string ?? ""
            return raw
                .components(separatedBy: .newlines)
                .map { PDFLayoutLine(text: $0, pageIndex: pageIndex) }
        }

        return selection.selectionsByLine().map { line in
            let attributed = line.attributedString ?? NSAttributedString(string: line.string ?? "")
            let metrics = fontMetrics(attributed)
            // Le retrait se mesure depuis le bord de la page : c'est lui qui dit
            // qu'une ligne « a) » est une question, décalée sous son exercice.
            let frame = line.bounds(for: page)
            let known = !(frame.isNull || frame.isInfinite) && bounds.height > 0
            let indent = known ? max(0, Double(frame.minX - bounds.minX)) : 0
            // PDF : l'origine est en bas. 0 = haut de page, 1 = bas.
            let vertical: Double? = known ? Double((bounds.maxY - frame.midY) / bounds.height) : nil
            return PDFLayoutLine(text: attributed.string,
                                 fontSize: Double(metrics.size),
                                 isBold: metrics.isBold,
                                 pageIndex: pageIndex,
                                 indent: indent,
                                 startsBold: startsBold(attributed),
                                 verticalPosition: vertical)
        }
    }

    /// Taille dominante de la ligne et graisse.
    ///
    /// La taille retenue est celle qui couvre le plus de caractères : une ligne de
    /// titre qui se termine par un mot en indice ne doit pas être jugée sur
    /// l'indice. La ligne est **grasse** si la majorité de ses caractères le sont —
    /// un seul mot en gras dans une phrase ne fait pas d'elle un titre (c'est ce
    /// que faisait l'ancienne règle, « au moins un passage gras »).
    private static func fontMetrics(_ attributed: NSAttributedString) -> (size: CGFloat, isBold: Bool) {
        guard attributed.length > 0 else { return (0, false) }
        var weightBySize: [CGFloat: Int] = [:]
        var boldCharacters = 0
        var counted = 0

        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            let visible = (attributed.string as NSString).substring(with: range)
                .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            weightBySize[font.pointSize, default: 0] += max(visible, 0)
            counted += visible
            if isBold(font) { boldCharacters += visible }
        }

        guard let dominant = weightBySize.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }) else { return (0, false) }
        return (dominant.key, counted > 0 && boldCharacters * 2 > counted)
    }

    /// La ligne s'ouvre-t-elle sur un passage en gras d'au moins trois caractères ?
    ///
    /// C'est la forme d'un titre « en ligne » (« **Exercice 2.** Soit… ») : la
    /// police dominante est celle du corps, mais le début dit « titre ».
    private static func startsBold(_ attributed: NSAttributedString) -> Bool {
        var boldPrefix = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, halt in
            let text = (attributed.string as NSString).substring(with: range)
            if boldPrefix == 0, text.trimmingCharacters(in: .whitespaces).isEmpty { return }
            guard let font = value as? PlatformFont, isBold(font) else {
                halt.pointee = true
                return
            }
            boldPrefix += text.trimmingCharacters(in: .whitespaces).count
        }
        return boldPrefix >= 3 && boldPrefix < attributed.length
    }

    /// Gras, d'après les traits **ou le nom** de la police.
    ///
    /// Les PDF produits par LaTeX embarquent des polices Type 1 (`CMBX10`,
    /// `LMRoman10-Bold`) dont les traits ne disent souvent rien : sans le nom,
    /// aucun titre de polycopié EPFL n'était vu comme gras.
    static func isBold(_ font: PlatformFont) -> Bool {
        #if canImport(UIKit)
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
        #else
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        #endif
        let name = font.fontName.lowercased()
        return ["bold", "cmbx", "cmb10", "black", "heavy", "semibold", "demi", "-bd", "sfbx", "bx10", "bx12"]
            .contains { name.contains($0) }
    }

    /// Texte brut, pour l'analyse par motifs et pour l'IA.
    static func plainText(_ lines: [PDFLayoutLine]) -> String {
        // On sépare les pages par une ligne vide : deux séries qui se suivent sur
        // des pages différentes ne doivent pas se coller.
        var result = ""
        var currentPage = lines.first?.pageIndex
        for line in lines {
            if line.pageIndex != currentPage {
                result += "\n"
                currentPage = line.pageIndex
            }
            result += line.text + "\n"
        }
        return result
    }
}
