import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Garder

/// Garder un document sous la main, le retirer, ajouter un fichier à soi.
@MainActor
enum ResourceLibrary {

    static func find(_ address: String, in course: Course) -> SavedResource? {
        let key = StudyLinkKey.key(address)
        return course.savedResources.first { !$0.address.isEmpty && StudyLinkKey.key($0.address) == key }
    }

    static func toggle(title: String, address: String, kind: SavedResource.Kind, in course: Course) {
        guard let context = course.modelContext else { return }
        if let existing = find(address, in: course) {
            context.delete(existing)
        } else {
            let resource = SavedResource(course: course, title: title.isEmpty ? address : title, address: address, kind: kind)
            context.insert(resource)
        }
        try? context.save()
    }

    /// Un fichier à soi (une fiche-résumé PDF, une photo de formulaire) : copié dans la base.
    @discardableResult
    static func add(file url: URL, to course: Course) -> SavedResource? {
        guard let context = course.modelContext else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: SavedResource.Kind = type?.conforms(to: .pdf) == true ? .pdf : (type?.conforms(to: .image) == true ? .image : .file)
        let resource = SavedResource(course: course, title: url.deletingPathExtension().lastPathComponent, kind: kind,
                                     fileName: url.lastPathComponent, fileData: data)
        resource.isPinned = true
        context.insert(resource)
        try? context.save()
        return resource
    }

    /// Le fichier d'une ressource ajoutée, écrit dans le cache pour l'ouvrir.
    static func fileURL(_ resource: SavedResource) -> URL? {
        guard let data = resource.fileData else { return nil }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack/resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (resource.fileName as NSString).pathExtension
        let file = directory.appendingPathComponent(resource.id.uuidString + (ext.isEmpty ? "" : "." + ext))
        if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        return file
    }

    /// Ce que le lecteur du cours ouvre pour cette ressource.
    static func reading(for resource: SavedResource) -> CoursePane.Reading? {
        if resource.isFile, let file = fileURL(resource) {
            return resource.kind == .pdf ? .pdf(title: resource.title, address: file.absoluteString)
                                         : .file(title: resource.title, address: file.absoluteString)
        }
        switch resource.kind {
        case .poly: return .botafogo(title: resource.title, url: resource.address)
        case .pdf: return .pdf(title: resource.title, address: resource.address)
        case .video: return .video(title: resource.title, address: resource.address)
        case .file, .image: return .file(title: resource.title, address: resource.address)
        case .web: return nil
        }
    }
}

/// Le signet d'un document ouvert : le garder dans « Gardés », ou l'en retirer.
struct SaveResourceButton: View {
    let course: Course
    let title: String
    let address: String
    let kind: SavedResource.Kind

    var body: some View {
        let saved = ResourceLibrary.find(address, in: course) != nil
        Button {
            ResourceLibrary.toggle(title: title, address: address, kind: kind, in: course)
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.paper)
        .help(saved ? "Retirer des ressources gardées" : "Garder sous la main (Cours › Gardés, et le menu Ressources du mode étude)")
        .disabled(address.isEmpty)
    }
}

// MARK: - Gardés

/// Les ressources du cours : épinglées d'abord, un clic les ouvre, un
/// fichier se glisse ici (ou « Ajouter un fichier »).
struct SavedResourcesList: View {
    @Bindable var course: Course
    var selected: String?
    var open: (SavedResource) -> Void

    @State private var importing = false
    @State private var dropping = false

    var body: some View {
        let tint = Carnet.tint(course.colorHex)
        List {
            Section {
                Button { importing = true } label: {
                    Label("Ajouter un fichier… (PDF, image)", systemImage: "plus.circle")
                        .foregroundStyle(Carnet.ink)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Garde ici ta fiche-résumé, un formulaire, un PDF du cours (le signet en haut d'un document) : à un clic, et sur tous tes appareils.")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkTertiary)
            }
            if !course.savedResources.isEmpty {
                Section("Gardés") {
                    ForEach(course.sortedResources) { resource in
                        Button { open(resource) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: resource.isPinned ? "pin.fill" : resource.kind.icon)
                                    .foregroundStyle(tint).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(resource.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                    Text(resource.isFile ? resource.fileName : (URL(string: resource.address)?.host ?? resource.address))
                                        .font(.caption).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected == resource.id.uuidString ? tint.opacity(0.12) : Color.clear)
                        .contextMenu {
                            Button(resource.isPinned ? "Désépingler" : "Épingler en tête") { resource.isPinned.toggle() }
                            Button("Retirer", role: .destructive) {
                                course.modelContext?.delete(resource)
                                try? course.modelContext?.save()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { ResourceLibrary.add(file: url, to: course) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { ResourceLibrary.add(file: url, to: course) }
            return !files.isEmpty
        } isTargeted: { dropping = $0 }
    }
}
