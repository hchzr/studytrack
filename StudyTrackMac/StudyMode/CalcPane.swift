import SwiftUI
import Charts

/// La calculatrice et le grapheur du bureau (`MathEngine`, pur et testé) :
/// ce qu'on allait chercher sur GeoGebra, sans quitter le mode étude.
struct CalcPane: View {
    var desk: StudyDesk
    var openWeb: (URL, String) -> Void

    @State private var line = ""
    @State private var range: ClosedRange<Double> = -5...5
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            calculator
                .frame(width: 420)
                .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Carnet.rule).frame(width: 1)
            graph
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { focused = true }
    }

    // MARK: Calcul

    private var calculator: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calcul").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                Spacer()
                Picker("Angles", selection: Binding(get: { desk.calc.degrees }, set: { desk.calc.degrees = $0 })) {
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
                                Text(entry.output)
                                    .font(entry.isError ? .callout : Carnet.clock(22))
                                    .foregroundStyle(entry.isError ? Carnet.wrong : Carnet.ink)
                                    .textSelection(.enabled)
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
                TextField("2x^2 - 3x + 1, f(x) = sin(x)/x", text: $line)
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
            ForEach(["sqrt(2)^3 - 2pi", "a = 3", "f(x) = x^3 - a x", "f'(1)", "int(f, 0, 2)", "root(f, 1, 3)", "binom(10, 3)"], id: \.self) { sample in
                Button {
                    line = sample
                    run()
                } label: {
                    Text(sample).font(.system(.callout, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Carnet.inkSecondary)
            }
            Text("f(x) = … se trace à droite.")
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
            if let value = try desk.calc.run(input) {
                desk.calcHistory.append((input, "= " + MathEngine.format(value), false))
            } else {
                desk.calcHistory.append((input, "tracée à droite", false))
            }
            line = ""
        } catch {
            desk.calcHistory.append((input, error.localizedDescription, true))
        }
    }

    // MARK: Graphe

    private var functionNames: [String] {
        desk.calc.functions.filter { $0.value.parameters.count == 1 }.keys.sorted()
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
                        let points = MathEngine.sample(name, from: range.lowerBound, to: range.upperBound, in: desk.calc)
                        ForEach(segments(points), id: \.first!.x) { segment in
                            ForEach(segment) { point in
                                LineMark(x: .value("x", point.x), y: .value("y", point.y),
                                         series: .value("f", "\(name)-\(segment.first!.x)"))
                                    .foregroundStyle(Self.colors[index % Self.colors.count])
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        ForEach(MathEngine.roots(name, from: range.lowerBound, to: range.upperBound, in: desk.calc), id: \.self) { root in
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
                    Text("\(name)(\(desk.calc.functions[name]?.parameters.first ?? "x"))").font(.callout.monospacedDigit())
                        .foregroundStyle(Carnet.ink)
                    Button {
                        desk.calc.functions[name] = nil
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
        let values = names.flatMap { MathEngine.sample($0, from: range.lowerBound, to: range.upperBound, in: desk.calc) }
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
