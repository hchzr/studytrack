import SwiftUI
import Charts

/// La calculatrice et le grapheur du bureau (`MathEngine`, pur et testé) :
/// ce qu'on allait chercher sur GeoGebra, sans quitter le mode étude.
struct CalcPane: View {
    var desk: CalcModel
    /// Une colonne (l'iPhone) plutôt que deux.
    var compact = false
    var openWeb: (URL, String) -> Void

    @State private var line = ""
    @State private var range: ClosedRange<Double> = -5...5
    @FocusState private var focused: Bool

    var body: some View {
        // Le Mac : la calculatrice à gauche, le graphe à droite. L'iPhone : l'un
        // sur l'autre, le graphe en haut quand il y a une fonction.
        Group {
        if compact {
            VStack(spacing: 0) {
                if !functionNames.isEmpty {
                    graph.frame(height: 300)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                }
                calculator
            }
        } else {
            HStack(spacing: 0) {
                calculator
                    .frame(width: 420)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(Carnet.rule).frame(width: 1)
                graph
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        }
        .onAppear {
            // Sur l'iPhone, le clavier n'apparaît qu'au toucher du champ.
            if !compact { focused = true }
            #if DEBUG
            // `-calcRun "x^2 - 2;z^5 = 1"` : des lignes déjà tapées, pour les captures.
            if let index = CommandLine.arguments.firstIndex(of: "-calcRun"), index + 1 < CommandLine.arguments.count, desk.calcHistory.isEmpty {
                for sample in CommandLine.arguments[index + 1].split(separator: ";") { line = String(sample); run() }
            }
            #endif
        }
    }

    // MARK: Calcul

    private var calculator: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calcul").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                Spacer()
                Picker("Angles", selection: Binding(get: { desk.workbench.engine.degrees }, set: { desk.workbench.engine.degrees = $0 })) {
                    Text("rad").tag(false)
                    Text("deg").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                Button { openWeb(URL(string: "https://www.geogebra.org/calculator")!, "GeoGebra") } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Carnet.inkSecondary)
                .help("GeoGebra")
            }
            .padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if desk.calcHistory.isEmpty { examples }
                        ForEach(Array(desk.calcHistory.enumerated()), id: \.offset) { index, entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.input)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(Carnet.inkSecondary)
                                CalcResult(result: entry.result)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { line = entry.input; focused = true }
                            .id(index)
                            PaperRule(inset: 16)
                        }
                    }
                }
                .onChange(of: desk.calcHistory.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            keypad
            HStack(spacing: 8) {
                Text("›").font(.title2).foregroundStyle(Carnet.inkTertiary)
                TextField("x^2 - 2, z^3 = i, det([[1,2],[3,4]])", text: $line)
                    .textFieldStyle(.plain)
                    .font(.system(.title3, design: .monospaced))
                    .focused($focused)
                    .onSubmit(run)
            }
            .padding(12)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
            .padding(12)
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comme sur papier").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
            ForEach(["x^3 - 2x", "x^2 = 2", "z^5 = 1", "(1+2i)/(3-i)", "A = [[1,2],[3,4]]", "inv(A)", "f'(1)", "int(f, 0, 2)"], id: \.self) { sample in
                Button {
                    line = sample
                    run()
                } label: {
                    Text(sample).font(.system(.callout, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Carnet.inkSecondary)
            }
            Text("Une expression en x se trace ; une équation se résout.")
                .font(.caption).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(16)
    }

    private var keypad: some View {
        let keys = ["π", "e", "√(", "^", "²", "!", "sin(", "cos(", "tan(", "ln(", "log(", "abs(", "(", ")", "x"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Button {
                    line += key == "√(" ? "sqrt(" : key
                    focused = true
                } label: {
                    Text(key.count > 1 ? key.replacingOccurrences(of: "(", with: "") : key)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Carnet.ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func run() {
        let input = line.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        do {
            desk.calcHistory.append((input, .success(try MathWorkbench.run(input, in: &desk.workbench))))
            line = ""
        } catch {
            desk.calcHistory.append((input, .failure(CalcError(message: error.localizedDescription))))
        }
    }

    // MARK: Graphe

    private var functionNames: [String] {
        desk.workbench.engine.functions.filter { $0.value.parameters.count == 1 }.keys.sorted()
    }

    private static let colors: [Color] = [Carnet.ink, Carnet.wrong, Carnet.correct, Carnet.review, Color(hex: "#5B6CC9")]

    private var graph: some View {
        let names = functionNames
        let span = range.upperBound - range.lowerBound
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Graphe").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                Spacer()
                Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { shift(-0.25) } label: { Image(systemName: "chevron.left") }
                Button { shift(0.25) } label: { Image(systemName: "chevron.right") }
                Button("−5…5") { range = -5...5 }
            }
            .buttonStyle(.paper)
            if names.isEmpty {
                ContentUnavailableView("Aucune fonction", systemImage: "function",
                                       description: Text("Essaie f(x) = x^2 - 2"))
            } else {
                Chart {
                    RuleMark(y: .value("0", 0)).foregroundStyle(Carnet.inkTertiary.opacity(0.6))
                    RuleMark(x: .value("0", 0)).foregroundStyle(Carnet.inkTertiary.opacity(0.6))
                    ForEach(Array(names.enumerated()), id: \.element) { index, name in
                        let points = MathEngine.sample(name, from: range.lowerBound, to: range.upperBound, in: desk.workbench.engine)
                        ForEach(segments(points), id: \.first!.x) { segment in
                            ForEach(segment) { point in
                                LineMark(x: .value("x", point.x), y: .value("y", point.y),
                                         series: .value("f", "\(name)-\(segment.first!.x)"))
                                    .foregroundStyle(Self.colors[index % Self.colors.count])
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        ForEach(MathEngine.roots(name, from: range.lowerBound, to: range.upperBound, in: desk.workbench.engine), id: \.self) { root in
                            PointMark(x: .value("x", root), y: .value("y", 0))
                                .foregroundStyle(Self.colors[index % Self.colors.count])
                                .annotation(position: .top) {
                                    Text(MathEngine.format((root * 1000).rounded() / 1000)).font(.caption2).foregroundStyle(Carnet.inkSecondary)
                                }
                        }
                    }
                }
                .chartXScale(domain: range)
                .chartYScale(domain: yDomain(names))
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Carnet.rule); AxisValueLabel() } }
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Carnet.rule); AxisValueLabel() } }
                .frame(minHeight: 380)
                .padding(12)
                .paperSheet(padding: 0)
                legend(names)
            }
            Text("\(MathEngine.format(range.lowerBound)) à \(MathEngine.format(range.upperBound))")
                .font(.caption).foregroundStyle(Carnet.inkTertiary)
        }
        .padding(16)
    }

    private func legend(_ names: [String]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                HStack(spacing: 6) {
                    Capsule().fill(Self.colors[index % Self.colors.count]).frame(width: 14, height: 3)
                    Text("\(name)(\(desk.workbench.engine.functions[name]?.parameters.first ?? "x"))").font(.callout.monospacedDigit())
                        .foregroundStyle(Carnet.ink)
                    Button {
                        desk.workbench.engine.functions[name] = nil
                    } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkTertiary)
                }
            }
        }
    }

    /// Un tracé coupé aux asymptotes : des morceaux continus.
    private func segments(_ points: [MathEngine.Point]) -> [[MathEngine.Point]] {
        let step = (range.upperBound - range.lowerBound) / 399
        var result: [[MathEngine.Point]] = []
        var current: [MathEngine.Point] = []
        for point in points {
            if let last = current.last, point.x - last.x > step * 1.5 || abs(point.y - last.y) > 1e4 {
                if current.count > 1 { result.append(current) }
                current = []
            }
            current.append(point)
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    /// L'axe des y : ce que les fonctions atteignent, sans les asymptotes.
    private func yDomain(_ names: [String]) -> ClosedRange<Double> {
        let values = names.flatMap { MathEngine.sample($0, from: range.lowerBound, to: range.upperBound, in: desk.workbench.engine) }
            .map(\.y).sorted()
        guard values.count > 4 else { return -5...5 }
        let low = values[Int(Double(values.count) * 0.02)], high = values[Int(Double(values.count) * 0.98)]
        let pad = max(0.5, (high - low) * 0.1)
        return (min(low, 0) - pad)...(max(high, 0) + pad)
    }

    private func zoom(_ factor: Double) {
        let mid = (range.lowerBound + range.upperBound) / 2
        let half = (range.upperBound - range.lowerBound) / 2 * factor
        range = (mid - half)...(mid + half)
    }

    private func shift(_ fraction: Double) {
        let delta = (range.upperBound - range.lowerBound) * fraction
        range = (range.lowerBound + delta)...(range.upperBound + delta)
    }
}

/// Un résultat, mis en forme selon ce qu'il est : nombre, solutions, matrice,
/// complexe (forme algébrique et polaire), fonction tracée.
private struct CalcResult: View {
    let result: Result<MathWorkbench.Output, CalcError>

    var body: some View {
        switch result {
        case .failure(let error):
            Text(error.message).font(.callout).foregroundStyle(Carnet.wrong)
        case .success(let output):
            switch output {
            case .value(let value):
                Text("= " + value).font(Carnet.clock(22)).foregroundStyle(Carnet.ink).textSelection(.enabled)
            case .plotted(let definition):
                Label(definition + " — tracée", systemImage: "chart.xyaxis.line").font(.callout).foregroundStyle(Carnet.ink)
            case .defined(let text):
                Text(text).font(.callout).foregroundStyle(Carnet.inkSecondary)
            case .complex(let value, let polar):
                VStack(alignment: .leading, spacing: 2) {
                    Text("= " + value).font(Carnet.clock(22)).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    Text(polar).font(.callout.monospaced()).foregroundStyle(Carnet.inkSecondary)
                }
            case .solutions(let variable, let roots):
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(roots.enumerated()), id: \.offset) { _, root in
                        Text("\(variable) = \(root)").font(.system(.title3, design: .monospaced)).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    }
                }
            case .matrix(let rows):
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(.system(.title3, design: .monospaced)).foregroundStyle(Carnet.ink)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(alignment: .leading) { Rectangle().fill(Carnet.ink).frame(width: 1.5) }
                .overlay(alignment: .trailing) { Rectangle().fill(Carnet.ink).frame(width: 1.5) }
                .textSelection(.enabled)
            }
        }
    }
}

struct CalcError: Error, Equatable { let message: String }

/// Ce que la calculatrice garde pendant la session : les définitions, l'historique.
@MainActor
@Observable
final class CalcModel {
    var workbench = MathWorkbench.Session()
    var calcHistory: [(input: String, result: Result<MathWorkbench.Output, CalcError>)] = []
}
