import SwiftUI
import AppKit

/// « Carnet » sur le Mac : le même papier et la même encre que l'iPhone.
///
/// L'app Mac parlait sa propre langue — dégradés, ombres, cartes grises du
/// système, couleurs de cours criardes — et ne ressemblait pas à l'iPhone. Ici,
/// les mêmes valeurs que `StudyTrack/App/Carnet.swift` (qui ne compile pas sur
/// macOS : il s'appuie sur UIKit) : fond crème, feuilles, encre, traits fins,
/// titres en serif, couleurs de cours adoucies. Plat par construction : la
/// profondeur vient du papier et des traits, jamais d'une ombre.
extension Carnet {
    // Le cœur (couleurs, serif, feuilles, boutons) est dans `StudyKit/CarnetCore.swift`,
    // partagé avec l'iPhone. Ici : les mesures de la fenêtre du Mac.
    static let sheetCorner: CGFloat = 14
    static let tileCorner: CGFloat = 8
    static let pagePadding: CGFloat = 32
}

extension NSAppearance {
}

// MARK: - Pastilles

/// Une pastille de cours : point de couleur, code.
struct CourseTag: View {
    let code: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(code).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
    }
}

/// Le verdict d'une correction : un mot, sa couleur, un glyphe (jamais la
/// couleur seule).
struct VerdictTag: View {
    let correctness: Correctness

    var body: some View {
        let color = Carnet.color(for: correctness)
        HStack(spacing: 4) {
            Image(systemName: glyph).font(.system(size: 8, weight: .heavy))
            Text(correctness.shortLabel)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var glyph: String {
        switch correctness {
        case .correct: return "checkmark"
        case .partial: return "equal"
        case .wrong: return "xmark"
        }
    }
}
