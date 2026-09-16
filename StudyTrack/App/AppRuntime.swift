import Foundation

/// Accès partagé au conteneur applicatif (utilisé par les App Intents / Siri).
@MainActor
enum AppRuntime {
    static var container: AppContainer?
}
