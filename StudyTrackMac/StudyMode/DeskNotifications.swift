import SwiftUI

/// La file des notifications du bureau (règles dans `DeskNotice`, testées). Remplace
/// la bulle « app fermée » et la bulle « depuis l'iPhone », qui se marchaient dessus.
@MainActor
@Observable
final class DeskNotifications {
    static let shared = DeskNotifications()

    private(set) var items: [DeskNotice.Item] = []
    /// Tout ce qui a été dit (vingt au plus), pour le relire dans le centre de contrôle.
    private(set) var history: [DeskNotice.Item] = []

    func post(_ kind: DeskNotice.Kind, _ text: String, icon: String) {
        let item = DeskNotice.Item(kind: kind, text: text, icon: icon, at: Date())
        items = DeskNotice.adding(item, to: items)
        let id = items.first { $0.kind == kind }?.id
        if let shown = items.first(where: { $0.kind == kind }) { history = DeskNotice.remembering(shown, in: history) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DeskNotice.duration(kind) + 0.2))
            self?.items.removeAll { $0.id == id && Date().timeIntervalSince($0.at) >= DeskNotice.duration(kind) }
        }
    }
}

/// Les notifications, en verre, en haut du bureau.
struct DeskNoticeStack: View {
    @State private var notifications = DeskNotifications.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(notifications.items) { item in
                Label(item.text, systemImage: item.icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudyPalette.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .deskGlass(in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.3), value: notifications.items)
    }
}
