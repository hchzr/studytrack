import SwiftUI

/// Le parcours : par où commencer, ce qui est à reprendre d'abord, et chaque notion dans
/// l'ordre où la comprendre (ce qui vient avant passe avant), avec où l'on en est.
struct LearningPathView: View {
    @Bindable var course: Course
    @Binding var concept: String?

    private var store: StudyMapStore { .shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    var body: some View {
        if let sheet = course.revisionSheet, !sheet.isEmpty {
            let map = store.map(course)
            let counts = LearningPath.counts(sheet: sheet, map: map)
            let order = LearningPath.order(sheet: sheet, map: map)
            let next = LearningPath.next(sheet: sheet, map: map)
            let weak = LearningPath.weakSpots(sheet: sheet, map: map, limit: 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary(counts)
                    if let next, let item = sheet.entry(forKey: next) { continueCard(item, level: map.mastery(next)) }
                    if !weak.isEmpty, counts.solid + counts.shaky > 0 { weakSection(weak, sheet: sheet, map: map) }
                    pathSection(order, sheet: sheet, map: map)
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Carnet.ground)
        } else {
            ContentUnavailableView("Pas encore de fiche", systemImage: "list.number")
        }
    }

    // MARK: Où j'en suis

    private func summary(_ counts: LearningPath.Counts) -> some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(Carnet.rule, lineWidth: 7)
                Circle().trim(from: 0, to: counts.fraction).stroke(Carnet.correct, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int((counts.fraction * 100).rounded())) %").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Carnet.ink)
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(counts.solid) notions solides sur \(counts.total)").font(Carnet.serif(20)).foregroundStyle(Carnet.ink)
                HStack(spacing: 12) {
                    ForEach(StudyMap.Mastery.allCases.reversed(), id: \.rawValue) { level in
                        let value = level == .solid ? counts.solid : (level == .shaky ? counts.shaky : counts.unknown)
                        HStack(spacing: 4) { MasteryDot(level: level, size: 11); Text("\(value) \(level.label.lowercased())").font(.caption).foregroundStyle(Carnet.inkSecondary) }
                    }
                }
            }
        }
    }

    private func continueCard(_ item: RevisionSheet.KeyedEntry, level: StudyMap.Mastery) -> some View {
        Button { concept = item.key } label: {
            HStack(spacing: 12) {
                Image(systemName: level == .unknown ? "play.circle.fill" : "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(level == .unknown ? "Commencer par" : "Reprendre").font(.caption).foregroundStyle(Carnet.inkSecondary)
                    MacMathText(item.entry.title, size: 16, design: .serif).foregroundStyle(Carnet.ink).lineLimit(2).multilineTextAlignment(.leading)
                    Text(item.chapterTitle).font(.caption).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func weakSection(_ keys: [String], sheet: RevisionSheet, map: StudyMap) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker("À reprendre d'abord")
            Text("Ce qui n'est pas solide et sur quoi d'autres notions s'appuient.").font(.caption).foregroundStyle(Carnet.inkSecondary)
            ForEach(keys, id: \.self) { key in
                if let item = sheet.entry(forKey: key) {
                    ConceptChip(title: item.entry.title, level: map.mastery(key)) { concept = key }
                }
            }
        }
    }

    // MARK: L'ordre

    private func pathSection(_ order: [String], sheet: RevisionSheet, map: StudyMap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("Dans l'ordre pour comprendre")
            ForEach(Array(order.enumerated()), id: \.element) { index, key in
                if let item = sheet.entry(forKey: key) {
                    Button { concept = key } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary).frame(width: 26, alignment: .trailing)
                            MasteryDot(level: map.mastery(key), size: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                MacMathText(item.entry.title, size: 14).foregroundStyle(Carnet.ink).lineLimit(2).multilineTextAlignment(.leading)
                                if let gist = map.enrichment[key]?.gist {
                                    Text(gist).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
