import Foundation
import Observation

// MARK: - Modèles distants (Supabase / Postgres)

struct RemoteGroup: Codable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var courseCode: String?
    var inviteCode: String
    var createdBy: String?
    /// Matières du groupe, ramenées par l'imbrication `group_courses(course_code)`.
    var groupCourses: [RemoteGroupCourse]?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case courseCode = "course_code"
        case inviteCode = "invite_code"
        case createdBy = "created_by"
        case groupCourses = "group_courses"
    }

    /// Toutes les matières, ancien champ compris.
    var subjectCodes: [String] {
        var codes = (groupCourses ?? []).map(\.courseCode)
        if let legacy = courseCode, !legacy.isEmpty { codes.append(legacy) }
        return StudyGroup.normalize(codes)
    }
}

/// L'adhésion **de l'utilisateur courant** à un groupe, avec son rôle.
///
/// Le rôle vit sur `group_members`, pas sur `study_groups` : le lire est
/// indispensable pour savoir si on peut administrer le groupe, et une lecture
/// imbriquée du seul groupe ne le donne pas.
struct RemoteMembership: Decodable {
    var role: String?
    var group: RemoteGroup?

    enum CodingKeys: String, CodingKey {
        case role
        case group = "study_groups"
    }
}

/// Une matière déclarée par un groupe.
struct RemoteGroupCourse: Codable {
    var courseCode: String

    enum CodingKeys: String, CodingKey {
        case courseCode = "course_code"
    }
}

/// Une matière qu'un membre suit au sein d'un groupe.
struct RemoteMemberCourse: Codable {
    var groupId: String
    var userId: String
    var courseCode: String

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case userId = "user_id"
        case courseCode = "course_code"
    }
}

/// « Untel travaille sur CS-250 en ce moment. »
struct RemotePresence: Codable {
    var userId: String
    var groupId: String
    var courseCode: String?
    var taskLabel: String?
    var target: String?
    var startedAt: String
    var updatedAt: String
    var profile: RemoteProfile?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case groupId = "group_id"
        case courseCode = "course_code"
        case taskLabel = "task_label"
        case target
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case profile = "profiles"
    }

    /// Convertit la ligne distante en valeur d'affichage.
    func entry(meID: String?) -> PresenceEntry? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = formatter.date(from: startedAt)
            ?? ISO8601DateFormatter().date(from: startedAt)
            ?? Date()
        let updated = formatter.date(from: updatedAt)
            ?? ISO8601DateFormatter().date(from: updatedAt)
            ?? Date()
        return PresenceEntry(userID: userId,
                             displayName: profile?.displayName ?? "Membre",
                             courseCode: courseCode ?? "",
                             taskLabel: taskLabel ?? "",
                             target: target ?? "",
                             startedAt: started,
                             updatedAt: updated,
                             isMe: userId == meID)
    }
}

struct RemoteMember: Codable, Identifiable {
    var groupId: String
    var userId: String
    var role: String?
    var profile: RemoteProfile?

    var id: String { "\(groupId)-\(userId)" }

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case userId = "user_id"
        case role, profile
    }
}

struct RemoteProfile: Codable {
    var id: String
    var displayName: String
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

struct RemoteStudyLog: Codable {
    var userId: String
    var groupId: String
    var courseCode: String?
    var taskType: String?
    var startedAt: String
    var durationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case groupId = "group_id"
        case courseCode = "course_code"
        case taskType = "task_type"
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
    }
}

struct RemoteSeriesCompletion: Codable {
    var groupId: String
    var userId: String
    var courseCode: String
    var seriesNumber: Int

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case userId = "user_id"
        case courseCode = "course_code"
        case seriesNumber = "series_number"
    }
}

struct RemoteItemCompletion: Codable {
    var groupId: String
    var userId: String
    var courseCode: String
    var itemKind: String
    var itemNumber: String

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case userId = "user_id"
        case courseCode = "course_code"
        case itemKind = "item_kind"
        case itemNumber = "item_number"
    }
}

struct RemotePlannedSession: Codable, Identifiable {
    var id: String
    var groupId: String?
    var courseCode: String?
    var title: String
    var startsAt: String
    var durationMinutes: Int
    var location: String?
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, title, location
        case groupId = "group_id"
        case courseCode = "course_code"
        case startsAt = "starts_at"
        case durationMinutes = "duration_minutes"
        case createdBy = "created_by"
    }
}

/// Ligne de classement calculée côté serveur (RPC `group_leaderboard`).
struct LeaderboardRow: Codable, Identifiable {
    var userId: String
    var displayName: String?
    var weeklySeconds: Int
    var totalSeconds: Int
    var seriesCompleted: Int

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case weeklySeconds = "weekly_seconds"
        case totalSeconds = "total_seconds"
        case seriesCompleted = "series_completed"
    }
}

// MARK: - Service social

/// Façade des fonctionnalités sociales (groupes, classements, planning partagé).
@Observable
final class SocialService {

    private(set) var client: SupabaseClient?
    private(set) var isSignedIn = false
    private(set) var userID: String?
    private(set) var email: String?
    private(set) var lastError: String?

    var isConfigured: Bool { client != nil }

    init(urlString: String = "", anonKey: String = "") {
        configure(urlString: urlString, anonKey: anonKey)
    }

    func configure(urlString: String, anonKey: String) {
        client = SupabaseClient(urlString: urlString, anonKey: anonKey)
        // La session est restaurée depuis le trousseau par le client : sans ce
        // report, l'app se croyait déconnectée à chaque lancement, et ni les
        // groupes ni la présence ne fonctionnaient — sans le moindre message.
        isSignedIn = client?.isSignedIn ?? false
        userID = client?.userID
        email = client?.userEmail
    }

    // MARK: Authentification

    func signInWithApple(idToken: String, nonce: String) async -> Bool {
        guard let client else {
            lastError = SupabaseError.notConfigured.localizedDescription
            return false
        }
        do {
            try await client.signInWithApple(idToken: idToken, nonce: nonce)
            isSignedIn = true
            userID = client.userID
            email = client.userEmail
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signUp(email value: String, password: String) async -> Bool {
        guard let client else {
            lastError = SupabaseError.notConfigured.localizedDescription
            return false
        }
        do {
            try await client.signUp(email: value, password: password)
            isSignedIn = true
            userID = client.userID
            email = client.userEmail
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signIn(email value: String, password: String) async -> Bool {
        guard let client else {
            lastError = SupabaseError.notConfigured.localizedDescription
            return false
        }
        do {
            try await client.signIn(email: value, password: password)
            isSignedIn = true
            userID = client.userID
            email = client.userEmail
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        await client?.signOut()
        isSignedIn = false
        userID = nil
        email = nil
    }

    /// Supprime le compte **et** tout ce qui en dépend sur le serveur (profil,
    /// adhésions, temps publié, avancement). Exigence App Store : un compte créé
    /// dans l'app doit pouvoir y être supprimé.
    ///
    /// Les données locales (cours, sessions) restent sur l'appareil : elles
    /// n'ont jamais dépendu du compte.
    func deleteAccount() async throws {
        guard let client, isSignedIn else { throw SupabaseError.notConfigured }
        do {
            try await client.rpc("delete_my_account", params: [:])
        } catch {
            lastError = "La suppression a échoué : \(error.localizedDescription)"
            throw error
        }
        await signOut()
        lastError = nil
    }

    // MARK: Groupes

    func createGroup(name: String,
                     description: String,
                     courseCode: String,
                     courseCodes: [String] = [],
                     displayName: String) async throws -> RemoteGroup {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }

        // Le profil **d'abord**. `study_groups.created_by` et `group_members.user_id`
        // référencent `profiles(id)` : insérer avant que la ligne existe viole la
        // clé étrangère, et faisait échouer la toute première création de groupe
        // d'un compte neuf.
        _ = try? await client.upsert("profiles",
                                     rows: [["id": userID, "display_name": displayName]],
                                     onConflict: "id")

        let subjects = StudyGroup.normalize(courseCodes.isEmpty ? [courseCode] : courseCodes)
        let inviteCode = StudyGroup.generateInviteCode()
        let payload: [String: Any] = [
            "name": name,
            "description": description,
            // `course_code` reste la **première** matière : c'est ce que lisent les
            // versions antérieures de l'app, et ça évite un groupe à moitié vide.
            "course_code": subjects.first ?? "",
            "invite_code": inviteCode,
            "created_by": userID
        ]
        let data = try await client.insert("study_groups", values: payload)
        guard let data, let group = try? JSONDecoder().decode([RemoteGroup].self, from: data).first else {
            throw SupabaseError.decoding("study_groups")
        }
        // L'adhésion du créateur. Elle **lance** si elle échoue : un groupe sans
        // son créateur côté serveur est invisible à la synchronisation et refuse
        // la présence — mieux vaut une erreur maintenant qu'un groupe fantôme.
        try await ensureMembership(groupID: group.id, role: .admin)
        if !subjects.isEmpty {
            _ = try? await client.insert("group_courses",
                                         rows: subjects.map {
                                             ["group_id": group.id, "course_code": $0]
                                         },
                                         returning: false)
            _ = try? await client.insert("member_courses",
                                         rows: subjects.map {
                                             ["group_id": group.id, "user_id": userID, "course_code": $0]
                                         },
                                         returning: false)
        }
        return group
    }

    func joinGroup(inviteCode: String, displayName: String) async throws -> RemoteGroup {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }

        // Même raison que dans `createGroup` : le profil avant l'adhésion.
        _ = try? await client.upsert("profiles",
                                     rows: [["id": userID, "display_name": displayName]],
                                     onConflict: "id")

        let data = try await client.select("study_groups",
                                           query: [URLQueryItem(name: "invite_code", value: "eq.\(inviteCode)"),
                                                   URLQueryItem(name: "select", value: "*")])
        guard let data, let group = try? JSONDecoder().decode([RemoteGroup].self, from: data).first else {
            throw SupabaseError.decoding("Aucun groupe avec ce code")
        }
        try await ensureMembership(groupID: group.id, role: .member)
        // On rejoint **toutes** les matières du groupe par défaut : c'est le cas
        // courant, et l'étudiant·e décoche ensuite celles qu'il ou elle ne suit pas.
        // L'ordre compte : la politique RLS de `group_courses` exige l'adhésion,
        // donc la lecture ne peut se faire qu'après l'insertion ci-dessus.
        if let codes = try? await fetchGroupCourses(groupID: group.id), !codes.isEmpty {
            _ = try? await client.insert("member_courses",
                                         rows: codes.map {
                                             ["group_id": group.id, "user_id": userID, "course_code": $0]
                                         })
        }
        return group
    }

    func fetchMyGroups() async throws -> [RemoteMembership] {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }
        func decode(_ data: Data?) -> [RemoteMembership] {
            guard let data else { return [] }
            return (try? JSONDecoder().decode([RemoteMembership].self, from: data)) ?? []
        }

        let memberFilter = URLQueryItem(name: "user_id", value: "eq.\(userID)")
        do {
            let data = try await client.select(
                "group_members",
                query: [memberFilter,
                        URLQueryItem(name: "select",
                                     value: "role,study_groups(*,group_courses(course_code))")])
            return decode(data)
        } catch {
            // Base antérieure à l'ajout de `group_courses` : l'imbrication fait
            // échouer la requête **entière**, ce qui viderait l'onglet Groupes
            // jusqu'à ce que le SQL soit relancé. On retombe sur la lecture simple,
            // quitte à ne pas connaître les matières pour l'instant.
            let data = try await client.select(
                "group_members",
                query: [memberFilter, URLQueryItem(name: "select", value: "role,study_groups(*)")])
            return decode(data)
        }
    }

    /// Supprime un groupe côté serveur. Les adhésions et le planning suivent par
    /// cascade (`on delete cascade` sur leurs clés étrangères).
    func deleteGroup(id: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client.delete("study_groups",
                                    query: [URLQueryItem(name: "id", value: "eq.\(id)")])
    }

    /// Retire un membre d'un groupe.
    ///
    /// Autorisé par les politiques RLS soit à l'intéressé·e lui-même, soit à un
    /// administrateur du groupe.
    func removeMember(groupID: String, userID: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client.delete("group_members",
                                    query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                            URLQueryItem(name: "user_id", value: "eq.\(userID)")])
    }

    /// Lit un groupe par son identifiant.
    ///
    /// `study_groups` est lisible par tout utilisateur connecté : le code
    /// d'invitation protège l'entrée, pas la lecture. C'est ce qui permet de
    /// vérifier qui a créé un groupe même quand on n'en est plus membre.
    func fetchGroup(id: String) async throws -> RemoteGroup? {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("study_groups",
                                           query: [URLQueryItem(name: "id", value: "eq.\(id)"),
                                                   URLQueryItem(name: "select", value: "*")])
        guard let data else { return nil }
        return (try? JSONDecoder().decode([RemoteGroup].self, from: data))?.first
    }

    /// Garantit mon adhésion à un groupe, avec le rôle voulu.
    ///
    /// L'insertion de l'adhésion était « best effort » (`try?`) à la création du
    /// groupe. Quand elle échouait, le groupe existait côté serveur **sans moi** :
    /// la synchronisation ne le revoyait jamais, l'avancement ne remontait pas, et
    /// publier ma présence était refusé par `is_group_member` — un `42501` que
    /// l'app affichait sans pouvoir le réparer.
    /// Crée mon adhésion si elle manque. Idempotent.
    ///
    /// **Jamais un upsert** ici : `ON CONFLICT DO UPDATE` déclenche la politique de
    /// mise à jour, réservée aux administrateurs — un simple membre qui rejoint
    /// deux fois se voyait refuser en 42501. Et **sans `RETURNING`** : la politique
    /// de lecture (« visible par les membres ») ne voit pas encore la ligne
    /// qu'on insère dans la même instruction, ce qui produisait « new row violates
    /// row-level security policy for table group_members » sur une insertion
    /// pourtant autorisée. Un doublon (23505) veut dire « déjà membre » : succès.
    func ensureMembership(groupID: String, role: GroupRole) async throws {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }
        do {
            _ = try await client.insert("group_members",
                                        values: ["group_id": groupID,
                                                 "user_id": userID,
                                                 "role": role.rawValue],
                                        returning: false)
        } catch let error as SupabaseError {
            if case .server(let status, let message) = error,
               status == 409 || message.contains("23505") || message.lowercased().contains("duplicate") {
                return
            }
            throw error
        }
    }

    /// Change le rôle d'un membre : « admin » ou « member ».
    func setMemberRole(groupID: String, userID: String, role: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client.update("group_members",
                                    query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                            URLQueryItem(name: "user_id", value: "eq.\(userID)")],
                                    values: ["role": role])
    }

    func fetchMembers(groupID: String) async throws -> [RemoteMember] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("group_members",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "group_id,user_id,role,profiles(*)")])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemoteMember].self, from: data)) ?? []
    }

    /// Quitte un groupe : on retire sa propre adhésion.
    ///
    /// À ne pas confondre avec `deleteGroup`, réservé au créateur : quitter ne
    /// détruit rien pour les autres, et c'est l'action que veut 99 % des gens.
    func leaveGroup(groupID: String) async throws {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }
        try await removeMember(groupID: groupID, userID: userID)
    }

    // MARK: Matières du groupe

    func fetchGroupCourses(groupID: String) async throws -> [String] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("group_courses",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "course_code")])
        guard let data else { return [] }
        let rows = (try? JSONDecoder().decode([RemoteGroupCourse].self, from: data)) ?? []
        return rows.map(\.courseCode)
    }

    /// Remplace la liste des matières d'un groupe.
    ///
    /// On supprime puis on réinsère : c'est la seule façon d'obtenir un « cet
    /// ensemble exact » avec PostgREST, et la table ne contient que quelques lignes.
    func setGroupCourses(groupID: String, codes: [String]) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client.delete("group_courses",
                                    query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)")])
        let normalized = StudyGroup.normalize(codes)
        guard !normalized.isEmpty else { return }
        _ = try await client.insert("group_courses",
                                    rows: normalized.map { ["group_id": groupID, "course_code": $0] })
    }

    func fetchMemberCourses(groupID: String) async throws -> [RemoteMemberCourse] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("member_courses",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "*")])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemoteMemberCourse].self, from: data)) ?? []
    }

    /// Déclare les matières que **je** suis dans ce groupe.
    func setMyCourses(groupID: String, codes: [String]) async throws {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }
        _ = try await client.delete("member_courses",
                                    query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                            URLQueryItem(name: "user_id", value: "eq.\(userID)")])
        let normalized = StudyGroup.normalize(codes)
        guard !normalized.isEmpty else { return }
        _ = try await client.insert("member_courses",
                                    rows: normalized.map {
                                        ["group_id": groupID, "user_id": userID, "course_code": $0]
                                    })
    }

    // MARK: Présence

    /// Publie « je travaille sur … » pour tous mes groupes.
    ///
    /// Sans effet si rien ne tourne (`entry == nil`) : on efface alors la ligne,
    /// pour qu'un chrono arrêté disparaisse immédiatement chez les autres.
    ///
    /// **Lance** au lieu d'avaler l'erreur : la table `presence` peut ne pas exister
    /// (SQL non relancé), et une présence qui ne se publie pas en silence est
    /// indétectable depuis l'app — c'est exactement ce qui s'est produit.
    func publishPresence(_ entry: PresenceEntry?, groupIDs: [String]) async throws {
        guard let client, let me = client.userID else { throw SupabaseError.notConfigured }
        guard !groupIDs.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        for groupID in groupIDs {
            if let entry {
                // `updated_at` est rafraîchi à chaque battement : c'est lui qui
                // décide, chez les autres, si je suis encore en ligne.
                let row: [String: Any] = [
                    "group_id": groupID,
                    "user_id": me,
                    "course_code": entry.courseCode,
                    "task_label": entry.taskLabel,
                    "target": entry.target,
                    "started_at": formatter.string(from: entry.startedAt),
                    "updated_at": formatter.string(from: Date())
                ]
                do {
                    _ = try await client.upsert("presence", rows: [row], onConflict: "group_id,user_id", returning: false)
                } catch let error as SupabaseError where Self.isMembershipRefusal(error) {
                    // « new row violates row-level security policy for table
                    // presence » : la politique exige `is_group_member`, et ma ligne
                    // d'adhésion manque côté serveur — groupe créé hors ligne, ou
                    // insertion d'adhésion perdue à la création. Le profil peut
                    // manquer aussi (clé étrangère). On répare les deux, puis on
                    // réessaie **une** fois ; un second refus est un vrai refus.
                    _ = try? await client.upsert("profiles",
                                                 rows: [["id": me, "display_name": entry.displayName]],
                                                 onConflict: "id")
                    try await ensureMembership(groupID: groupID, role: .member)
                    _ = try await client.upsert("presence", rows: [row], onConflict: "group_id,user_id", returning: false)
                }
            } else {
                // Seulement **ma** ligne : sans le filtre `user_id`, arrêter mon
                // chrono effacerait la présence de tout le groupe.
                _ = try await client.delete("presence",
                                            query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                    URLQueryItem(name: "user_id", value: "eq.\(me)")])
            }
        }
    }

    /// Un refus RLS (42501) ou une clé étrangère vers `profiles` (23503) : dans les
    /// deux cas, c'est mon adhésion ou mon profil qui manque — réparable.
    private static func isMembershipRefusal(_ error: SupabaseError) -> Bool {
        guard case .server(let status, let message) = error else { return false }
        let lower = message.lowercased()
        return (status == 401 || status == 403 || status == 409)
            && (lower.contains("row-level security") || lower.contains("42501") || lower.contains("23503"))
    }

    func fetchPresence(groupID: String) async throws -> [PresenceEntry] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("presence",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "*,profiles(display_name)")])
        guard let data else { return [] }
        let rows = (try? JSONDecoder().decode([RemotePresence].self, from: data)) ?? []
        return rows.compactMap { $0.entry(meID: client.userID) }
    }

    // MARK: Classement & avancement

    func fetchLeaderboard(groupID: String) async throws -> [LeaderboardRow] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.rpc("group_leaderboard", params: ["p_group_id": groupID])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([LeaderboardRow].self, from: data)) ?? []
    }

    func pushStudyLogs(_ logs: [RemoteStudyLog]) async {
        guard let client, !logs.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(logs) else { return }
        _ = try? await client.request("/rest/v1/study_log_public",
                                      method: "POST",
                                      body: data,
                                      prefer: "return=minimal")
    }

    func pushSeriesCompletion(groupID: String, courseCode: String, seriesNumber: Int) async {
        guard let client, let userID = client.userID else { return }
        _ = try? await client.upsert("series_completion",
                                     rows: [[
                                        "group_id": groupID,
                                        "user_id": userID,
                                        "course_code": courseCode,
                                        "series_number": seriesNumber
                                     ]],
                                     onConflict: "group_id,user_id,course_code,series_number")
    }

    /// Pousse l'avancement **exercice par exercice** vers un groupe.
    ///
    /// En lot : un import de série peut en marquer vingt d'un coup, et vingt allers-
    /// retours séquentiels sur le fil principal se voient.
    func pushItemCompletions(_ items: [RemoteItemCompletion]) async {
        guard let client, client.userID != nil, !items.isEmpty else { return }
        let rows: [[String: Any]] = items.map { item in
            ["group_id": item.groupId,
             "user_id": item.userId,
             "course_code": item.courseCode,
             "item_kind": item.itemKind,
             "item_number": item.itemNumber]
        }
        _ = try? await client.upsert("item_completion",
                                     rows: rows,
                                     onConflict: "group_id,user_id,course_code,item_kind,item_number")
    }

    func fetchItemCompletions(groupID: String) async throws -> [RemoteItemCompletion] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("item_completion",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "*")])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemoteItemCompletion].self, from: data)) ?? []
    }

    func fetchSeriesCompletions(groupID: String) async throws -> [RemoteSeriesCompletion] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("series_completion",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "*")])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemoteSeriesCompletion].self, from: data)) ?? []
    }

    // MARK: Planning partagé

    func fetchPlannedSessions(groupID: String) async throws -> [RemotePlannedSession] {
        guard let client else { throw SupabaseError.notConfigured }
        let data = try await client.select("planned_sessions",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "*"),
                                                   URLQueryItem(name: "order", value: "starts_at.asc")])
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RemotePlannedSession].self, from: data)) ?? []
    }

    func createPlannedSession(groupID: String,
                              courseCode: String,
                              title: String,
                              startsAt: Date,
                              durationMinutes: Int,
                              location: String) async throws -> RemotePlannedSession {
        guard let client, let userID = client.userID else { throw SupabaseError.notConfigured }
        let payload: [String: Any] = [
            "group_id": groupID,
            "course_code": courseCode,
            "title": title,
            "starts_at": ISO8601DateFormatter().string(from: startsAt),
            "duration_minutes": durationMinutes,
            "location": location,
            "created_by": userID
        ]
        let data = try await client.insert("planned_sessions", values: payload)
        guard let data, let session = try? JSONDecoder().decode([RemotePlannedSession].self, from: data).first else {
            throw SupabaseError.decoding("planned_sessions")
        }
        return session
    }

    func setRSVP(sessionID: String, status: RSVPStatus) async {
        guard let client, let userID = client.userID else { return }
        _ = try? await client.upsert("session_rsvps",
                                     rows: [[
                                        "session_id": sessionID,
                                        "user_id": userID,
                                        "status": status.rawValue
                                     ]],
                                     onConflict: "session_id,user_id")
    }
}

/// Helper Sign in with Apple (nonce + hachage).
enum AppleSignInSupport {
    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }
}
