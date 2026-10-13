import SwiftUI

/// Un texte avec des formules, comme `MathText` sur l'iPhone : indices et
/// exposants à leur place, symboles au lieu des commandes (`MathMarkup`).
struct MacMathText: View {
    let source: String
    var size: CGFloat = 14
    var design: Font.Design = .default

    init(_ source: String, size: CGFloat = 14, design: Font.Design = .default) {
        self.source = source
        self.size = size
        self.design = design
    }

    var body: some View {
        Self.text(source, size: size, design: design)
            .accessibilityLabel(MathMarkup.plain(source))
    }

    static func text(_ source: String, size: CGFloat, design: Font.Design = .default, weight: Font.Weight = .regular) -> Text {
        let font = Font.system(size: size, weight: weight, design: design)
        guard MathMarkup.hasMarkup(source) else { return Text(source).font(font) }
        let small = Font.system(size: size * 0.72, weight: weight, design: design)
        return MathMarkup.runs(source).reduce(Text("")) { text, run in
            switch run.style {
            case .normal: return text + Text(run.text).font(font)
            case .superscripted: return text + Text(run.text).font(small).baselineOffset(size * 0.38)
            case .subscripted: return text + Text(run.text).font(small).baselineOffset(-size * 0.2)
            }
        }
    }
}

/// Une réponse de Claude, mise en page nativement : titres en serif,
/// paragraphes, listes, formules (centrées quand elles sont isolées), code.
struct RichTextView: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(RichMarkup.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: RichMarkup.Block) -> some View {
        switch block {
        case .heading(let title, let level):
            Self.inline(title, size: level <= 2 ? size * 1.3 : size * 1.1, weight: .semibold, design: .serif)
                .foregroundStyle(Carnet.ink)
                .padding(.top, 4)
        case .paragraph(let body):
            Self.inline(body, size: size)
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        case .bullet(let body, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(Carnet.inkSecondary)
                Self.inline(body, size: size).foregroundStyle(Carnet.ink).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .numbered(let body, let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").monospacedDigit().foregroundStyle(Carnet.inkSecondary)
                Self.inline(body, size: size).foregroundStyle(Carnet.ink).fixedSize(horizontal: false, vertical: true)
            }
        case .math(let formula):
            DisplayMathView(tex: formula, size: size)
                .foregroundStyle(Carnet.ink)
        case .code(let code):
            Text(code)
                .font(.system(size: size * 0.9, design: .monospaced))
                .foregroundStyle(Carnet.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            PaperRule()
        }
    }

    /// Une ligne : gras, italique, code, formules (mises en page), liens.
    @MainActor
    static func inline(_ text: String, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Text {
        RichMarkup.inlines(text).reduce(Text("")) { result, piece in
            switch piece {
            case .text(let value):
                return result + Text(value).font(.system(size: size, weight: weight, design: design))
            case .bold(let value):
                return result + MacMathText.text(value, size: size, design: design, weight: .semibold)
            case .italic(let value):
                return result + MacMathText.text(value, size: size, design: design, weight: weight).italic()
            case .code(let value):
                return result + Text(value).font(.system(size: size * 0.92, design: .monospaced))
            case .math(let value):
                return result + (MathTypeset.inline(value, size: size)
                    ?? MacMathText.text(value, size: size, design: .serif, weight: weight))
            case .link(let title, let url):
                var link = AttributedString(title)
                link.link = URL(string: url)
                link.underlineStyle = .single
                return result + Text(link).font(.system(size: size, weight: weight, design: design))
            }
        }
    }
}
