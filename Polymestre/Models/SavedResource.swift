import Foundation
import SwiftData

/// Une ressource gardée sous la main : une fiche-résumé, un formulaire, un
/// PDF du cours, une section du polycopié, un lien. Soit une **adresse**
/// (document du cours, page, section), soit un **fichier** ajouté par
/// l'étudiant·e — rangé dans la base (`externalStorage`), donc sur tous ses
/// appareils par iCloud.
@Model
final class SavedResource {
    enum Kind: String, CaseIterable {
        case pdf, web, poly, video, file, image

        var icon: String {
            switch self {
            case .pdf: return "doc.richtext"
            case .web: return "safari"
            case .poly: return "text.book.closed"
            case .video: return "play.rectangle"
            case .file: return "doc"
            case .image: return "photo"
            }
        }
    }

    var id: UUID = UUID()
    var course: Course?
    var title: String = ""
    /// L'adresse (ou le chemin du polycopié) ; vide pour un fichier ajouté.
    var address: String = ""
    var kindRaw: String = ""
    /// Le nom du fichier ajouté (son extension dit comment l'ouvrir).
    var fileName: String = ""
    @Attribute(.externalStorage) var fileData: Data?
    var addedAt: Date = Date.now
    /// Épinglée en tête (la fiche-résumé qu'on rouvre sans cesse).
    var isPinned: Bool = false

    init(course: Course?, title: String, address: String = "", kind: Kind, fileName: String = "", fileData: Data? = nil) {
        self.course = course
        self.title = title
        self.address = address
        self.kindRaw = kind.rawValue
        self.fileName = fileName
        self.fileData = fileData
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .web }
        set { kindRaw = newValue.rawValue }
    }

    var isFile: Bool { fileData != nil }
}
