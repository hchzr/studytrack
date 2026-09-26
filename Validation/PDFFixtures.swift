import Foundation
import CoreText
import CoreGraphics

/// De **vrais** PDF, dessinés avec CoreText, pour tester la chaîne complète :
/// extraction de la mise en page (PDFKit), parseur, et déduction de la série.
///
/// Les tests sur des lignes fabriquées à la main vérifient la logique ; ceux-ci
/// vérifient que PDFKit rend bien ce que la logique attend — tailles, gras,
/// retraits, pages. Trois mises en page réelles de polycopiés y sont reproduites.
struct FixtureLine {
    var text: String
    var size: CGFloat = 11
    var bold = false
    var indent: CGFloat = 0
    /// Nombre de caractères en gras au début de la ligne (titre « en ligne »).
    var boldPrefix = 0
    /// Texte d'une seconde colonne, sur la même ligne de base (x = 330).
    var column2: String? = nil
    /// Dessinée en bas de page, comme un vrai pied de page.
    var footer = false
}

enum PDFFixtures {

    static func write(_ pages: [[FixtureLine]], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 842 - 60
            for line in page {
                let regular = CTFontCreateWithName("Times-Roman" as CFString, line.size, nil)
                let bold = CTFontCreateWithName("Times-Bold" as CFString, line.size, nil)
                let key = NSAttributedString.Key(kCTFontAttributeName as String)
                let attributed = NSMutableAttributedString(string: line.text,
                                                           attributes: [key: line.bold ? bold : regular])
                if line.boldPrefix > 0 {
                    attributed.addAttribute(key, value: bold,
                                            range: NSRange(location: 0, length: min(line.boldPrefix, attributed.length)))
                }
                context.textPosition = CGPoint(x: 56 + line.indent, y: line.footer ? 40 : y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                if line.footer { continue }
                if let column2 = line.column2 {
                    let second = NSAttributedString(string: column2, attributes: [key: regular])
                    context.textPosition = CGPoint(x: 330, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(second), context)
                }
                y -= line.size * 1.6
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Polycopié français : la série n'est que dans l'en-tête courant, des
    /// questions a) b) décalées, un bonus, une démonstration numérotée et une
    /// citation qui ne doivent pas devenir des exercices, un titre sur deux
    /// lignes et un titre « en ligne » en page 2.
    static let analyse: [[FixtureLine]] = [
        [
            FixtureLine(text: "EPFL · Analyse I · Automne 2026 · Série 4", size: 9),
            FixtureLine(text: "Exercice 1 (Changement de variable)", size: 12, bold: true),
            FixtureLine(text: "Calculer les intégrales suivantes :"),
            FixtureLine(text: "a) l'intégrale de x exp(x) sur [0, 1] ;", indent: 22),
            FixtureLine(text: "b) l'intégrale de sin(x) au carré sur [0, pi].", indent: 22),
            FixtureLine(text: "Exercice 2 (facultatif)", size: 12, bold: true),
            FixtureLine(text: "Montrer que l'intégrale converge."),
            FixtureLine(text: "1.5 Montrer d'abord que f est bornée sur l'intervalle [0, 1]."),
            FixtureLine(text: "Exercice 3 de la série 3 nous a montré que la limite existe.")
        ],
        [
            FixtureLine(text: "EPFL · Analyse I · Automne 2026 · Série 4", size: 9),
            FixtureLine(text: "Exercice 3", size: 12, bold: true),
            FixtureLine(text: "Intégrale impropre", size: 12, bold: true),
            FixtureLine(text: "Étudier la convergence de l'intégrale."),
            FixtureLine(text: "Exercice 4. Soit f une fonction continue sur R.", boldPrefix: 11)
        ]
    ]

    /// Master en anglais : « Exercise Set 7 », titres en ligne, questions (a) (b),
    /// un exercice optionnel.
    static let english: [[FixtureLine]] = [
        [
            FixtureLine(text: "Exercise Set 7", size: 16, bold: true),
            FixtureLine(text: "Problem 1. Let f be a continuous function on [0, 1].", boldPrefix: 10),
            FixtureLine(text: "(a) Show that f is bounded.", indent: 22),
            FixtureLine(text: "(b) Deduce that f attains its maximum.", indent: 22),
            FixtureLine(text: "Problem 2 (optional). Compute the limit of the sequence.", boldPrefix: 10),
            FixtureLine(text: "Problem 3. Prove the claim of the lecture.", boldPrefix: 10)
        ]
    ]

    /// La mise en page d'un vrai polycopié d'Analyse I (série 03) : « Ex-03-01: »
    /// en gras, deux niveaux de questions (1) puis (a)…(e)), une liste en deux
    /// colonnes, et un pied de page répété.
    static let nested: [[FixtureLine]] = [
        [
            FixtureLine(text: "Série 03 (Suites)", size: 14, bold: true),
            FixtureLine(text: "Ex-03-01:", bold: true),
            FixtureLine(text: "1) Soit (xn) la suite dont le graphe est le suivant :", indent: 14),
            FixtureLine(text: "(a) l'ensemble A", indent: 35),
            FixtureLine(text: "(b) l'ensemble B", indent: 34),
            FixtureLine(text: "(c) l'ensemble C", indent: 36),
            FixtureLine(text: "2) Soit (yn) la suite dont le graphe est le suivant :", indent: 14),
            FixtureLine(text: "(a) l'ensemble A'", indent: 35),
            FixtureLine(text: "(b) l'ensemble B'", indent: 34),
            FixtureLine(text: "(c) un entier N", indent: 36),
            FixtureLine(text: "(d) l'ensemble C'", indent: 34),
            FixtureLine(text: "(e) un entier N", indent: 35),
            FixtureLine(text: "Compilation: 2026-09-19. Version Web", size: 6, footer: true)
        ],
        [
            FixtureLine(text: "Ex-03-02: Soit (xn) la suite définie par xn = 1/n.", boldPrefix: 9),
            FixtureLine(text: "Ex-03-03: Pour chacune des suites ci-dessous, montrer la limite.", boldPrefix: 9),
            FixtureLine(text: "1) an = n/(n+1)", indent: 14, column2: "3) an = (-1)^n/n"),
            FixtureLine(text: "2) an = 1/n", indent: 14, column2: "4) an = n/(n^2+1)"),
            FixtureLine(text: "Ensuite, pour la suite an = 2n/(n+1), donner l'ensemble des n."),
            FixtureLine(text: "Compilation: 2026-09-19. Version Web", size: 6, footer: true)
        ],
        [
            // Une consigne avant la liste, séparée d'elle par « Ensuite ».
            FixtureLine(text: "Ex-03-11: Soit an = 3n/(n+2). Calculer la limite de an, à l'aide de la définition.", boldPrefix: 9),
            FixtureLine(text: "Ensuite, en utilisant les propriétés de la limite, calculer :"),
            FixtureLine(text: "1) lim 1/an", indent: 14, column2: "3) lim 9n^2/(n^2+4n+4)"),
            FixtureLine(text: "2) lim (an/3 + 3/an)", indent: 14),
            // Une liste de conditions : l'énoncé, pas du travail à cocher.
            FixtureLine(text: "Ex-03-12: Montrer qu'il existe une suite (xn) qui satisfait les conditions suivantes :", boldPrefix: 9),
            FixtureLine(text: "1) xn est dans A pour tout n,", indent: 14),
            FixtureLine(text: "2) xn tend vers s.", indent: 14),
            FixtureLine(text: "Compilation: 2026-09-19. Version Web", size: 6, footer: true)
        ]
    ]

    /// Aucun mot-clé : des titres numérotés en gras.
    static let numbered: [[FixtureLine]] = [
        [
            FixtureLine(text: "Série 2 — Algèbre linéaire", size: 16, bold: true),
            FixtureLine(text: "1. Espaces vectoriels", size: 12, bold: true),
            FixtureLine(text: "Montrer que E est un espace vectoriel."),
            FixtureLine(text: "2. Applications linéaires", size: 12, bold: true),
            FixtureLine(text: "Soit f : E vers F une application."),
            FixtureLine(text: "3. Noyau et image", size: 12, bold: true),
            FixtureLine(text: "Déterminer le noyau de f.")
        ]
    ]
}
