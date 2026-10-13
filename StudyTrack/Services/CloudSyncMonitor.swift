import Foundation
import CoreData
import CloudKit
import SwiftData

/// Ce qui suit l'arrivée de données d'un autre appareil (iCloud).
///
/// iCloud importe par lots, en arrière-plan : on attend que ça se calme
/// (quelques secondes sans nouvel import), puis on fusionne les doublons, on
/// rafraîchit les widgets, et un nouvel appareil dont les cours viennent
/// d'arriver saute l'accueil — il n'a rien à importer.
@MainActor
enum CloudSyncMonitor {
    private static var pending: Task<Void, Never>?

    /// Le nom de la notification d'import distant de Core Data.
    static let remoteChange = Notification.Name.NSPersistentStoreRemoteChange

    static func remoteChangeArrived(container: AppContainer) {
        guard container.isCloudSynced else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await settle(container: container)
        }
    }

    static func settle(container: AppContainer) async {
        let merged = await SyncDeduplicator.runInBackground(container.modelContainer)
        let context = ModelContext(container.modelContainer)
        if merged.total > 0 {
            AppLog.record(.info, AppLog.Category.storage, "Doublons iCloud fusionnés", detail: merged.summary)
        }
        let settings = container.settings
        if !settings.hasCompletedOnboarding, !settings.deviceHasOnboarded {
            let tracked = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
            if !tracked.isEmpty {
                settings.hasCompletedOnboarding = true
                settings.contentRefreshNews = "iCloud : \(tracked.count) cours retrouvé\(tracked.count > 1 ? "s" : "")"
            }
        }
        WidgetSnapshotWriter.refresh(context: ModelContext(container.modelContainer), settings: settings)
    }

    // MARK: Compte iCloud

    enum Account: Equatable {
        case available, noAccount, restricted, unknown
    }

    static func accountStatus() async -> Account {
        guard let status = try? await CKContainer(identifier: AppContainer.cloudContainerID).accountStatus() else {
            return .unknown
        }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        default: return .unknown
        }
    }
}
