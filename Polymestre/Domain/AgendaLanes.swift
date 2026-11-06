import Foundation

/// Les événements d'un jour qui se chevauchent, côte à côte : chacun prend la première colonne
/// libre de son groupe, et le groupe (tout ce qui se touche, de proche en proche) se partage la
/// largeur. Pur, testé (`validate.sh`).
enum AgendaLanes {
    struct Slot: Equatable {
        var lane: Int
        var lanes: Int
    }

    /// `intervals[i]` → sa colonne et le nombre de colonnes de son groupe, dans le même ordre.
    static func assign(_ intervals: [(start: Date, end: Date)]) -> [Slot] {
        let order = intervals.indices.sorted {
            intervals[$0].start != intervals[$1].start ? intervals[$0].start < intervals[$1].start
                : intervals[$0].end > intervals[$1].end
        }
        var slots = [Slot](repeating: Slot(lane: 0, lanes: 1), count: intervals.count)
        var group: [Int] = []
        var laneEnds: [Date] = []
        var groupEnd = Date.distantPast

        func close() {
            for index in group { slots[index].lanes = max(1, laneEnds.count) }
            group = []
            laneEnds = []
        }

        for index in order {
            let (start, end) = (intervals[index].start, max(intervals[index].end, intervals[index].start))
            if start >= groupEnd { close() }
            if let free = laneEnds.firstIndex(where: { $0 <= start }) {
                laneEnds[free] = end
                slots[index].lane = free
            } else {
                laneEnds.append(end)
                slots[index].lane = laneEnds.count - 1
            }
            group.append(index)
            groupEnd = group.count == 1 ? end : max(groupEnd, end)
        }
        close()
        return slots
    }
}
