import Foundation

/// La géométrie du bureau d'étude : où poser la fenêtre d'une app permise pour
/// qu'elle remplisse le centre du bureau, la barre du haut, la colonne d'outils
/// et le volet d'à côté restant visibles autour d'elle.
///
/// Deux repères se croisent : AppKit mesure depuis le **bas** de l'écran principal,
/// l'Accessibilité depuis son **haut**. Tout est pur et testé ici ; poser la
/// fenêtre est dans `PolymestreMac/StudyMode/AppPlacement.swift`.
enum DeskGeometry {

    struct Rect: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var maxX: Double { x + width }
        var maxY: Double { y + height }

        func contains(_ other: Rect, tolerance: Double = 2) -> Bool {
            other.x >= x - tolerance && other.y >= y - tolerance
                && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
        }
    }

    /// Le centre du bureau en repère de l'Accessibilité (origine en haut à gauche de
    /// l'écran principal) : `window` est la fenêtre du bureau en repère AppKit
    /// (origine en bas), `local` le centre dans la fenêtre, mesuré depuis son coin
    /// supérieur gauche (ce que donne SwiftUI).
    static func accessibilityRect(window: Rect, local: Rect, primaryHeight: Double) -> Rect {
        let windowTop = primaryHeight - window.maxY
        return Rect(x: window.x + local.x, y: windowTop + local.y, width: local.width, height: local.height)
    }

    /// Où poser une fenêtre dans `hole`.
    ///
    /// - Redimensionnable : elle remplit le trou.
    /// - Sinon, ou si l'app refuse d'être aussi petite (`minimum`) : sa taille, ramenée
    ///   dans le trou si elle y tient, centrée dedans.
    static func placement(current: Rect, minimum: (width: Double, height: Double)?, resizable: Bool, in hole: Rect) -> Rect {
        if resizable {
            let width = max(hole.width, minimum?.width ?? 0)
            let height = max(hole.height, minimum?.height ?? 0)
            return centred(width: width, height: height, in: hole)
        }
        return centred(width: current.width, height: current.height, in: hole)
    }

    /// Une fenêtre de cette taille, au centre du trou ; trop grande, elle part du
    /// coin haut-gauche du trou (la barre de titre reste atteignable).
    static func centred(width: Double, height: Double, in hole: Rect) -> Rect {
        let x = width >= hole.width ? hole.x : hole.x + (hole.width - width) / 2
        let y = height >= hole.height ? hole.y : hole.y + (hole.height - height) / 2
        return Rect(x: x, y: y, width: width, height: height)
    }
}

/// Où vont les fenêtres du bureau d'étude sur un écran (repère AppKit : origine en
/// bas à gauche) : la barre du haut, la colonne d'outils, le centre et, à part, le
/// volet d'à côté. Le Dock, s'il est visible, n'est jamais recouvert par le centre
/// (`visible` l'exclut) ; la barre, elle, recouvre la barre des menus de macOS.
enum PanelLayout {
    struct Frames: Equatable {
        var bar: DeskGeometry.Rect
        var rail: DeskGeometry.Rect
        var desk: DeskGeometry.Rect
        var side: DeskGeometry.Rect?
    }

    /// - `sideWidth` : la largeur du volet quand il est ouvert (`nil` : fermé).
    /// - `secondScreen` : le volet occupe tout cet autre écran.
    static func frames(screen f: DeskGeometry.Rect, visible v: DeskGeometry.Rect, bar: Double, rail: Double,
                       sideWidth: Double?, secondScreen: DeskGeometry.Rect?) -> Frames {
        let left = max(0, v.x - f.x), right = max(0, f.maxX - v.maxX), bottom = max(0, v.y - f.y)
        let y0 = f.y + bottom
        let height = f.height - bar - bottom
        let contentLeft = f.x + left + rail - 1
        let contentRight = f.maxX - right
        let onThisScreen = secondScreen == nil ? sideWidth : nil
        let desk = DeskGeometry.Rect(x: contentLeft, y: y0, width: contentRight - contentLeft - (onThisScreen ?? 0), height: height + 1)
        var side: DeskGeometry.Rect?
        if let sideWidth {
            side = secondScreen ?? DeskGeometry.Rect(x: contentRight - sideWidth, y: y0, width: sideWidth, height: height)
        }
        return Frames(bar: DeskGeometry.Rect(x: f.x, y: f.maxY - bar, width: f.width, height: bar),
                      rail: DeskGeometry.Rect(x: f.x + left, y: y0, width: rail, height: height),
                      desk: desk, side: side)
    }
}

/// Ce qu'il manque avant de commencer un blocage : à demander **sur l'écran de
/// lancement**, car sous blocage les Réglages Système sont fermés.
enum StudyReadiness {
    enum Missing: Equatable {
        /// Placer les apps permises dans le bureau (Accessibilité).
        case accessibility
        /// Cacher le Dock et la barre des menus (System Events).
        case systemEvents
    }

    static func missing(blocking: Bool, placeApps: Bool, trusted: Bool, hideChrome: Bool, automationGranted: Bool) -> [Missing] {
        guard blocking else { return [] }
        var result: [Missing] = []
        if placeApps && !trusted { result.append(.accessibility) }
        if hideChrome && !automationGranted { result.append(.systemEvents) }
        return result
    }
}

extension StudyMode {
    /// Les apps où l'on écrit : quand l'une d'elles occupe le centre pendant un
    /// exercice, l'énoncé passe dans le volet d'à côté.
    static let writingApps: Set<String> = ["com.goodnotesapp.x", "com.apple.Notes", "com.apple.Preview"]
}
