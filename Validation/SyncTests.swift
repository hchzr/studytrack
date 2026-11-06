import Foundation
import SwiftData

// Contrôles de la synchronisation Supabase (Polymestre/Domain/Sync*.swift).
//
// Reprend les cas de windows/tests/sync.test.ts (arrivée d'un appareil à l'autre,
// plus récent gagne, local plus récent non écrasé, cascade / mise à nul, orphelin
// ajouté hors ligne, lecture par pages, deux passes concurrentes), plus ce que
// SwiftData impose : pas d'écho, adoption d'un contenu identique (iCloud), pierres
// tombales minimales, garde-fou de suppression massive.

/// Le serveur simulé : les règles de `sync_guard` (la plus récente écriture gagne,
/// le serveur pose `server_updated_at`, la réponse porte la version gardée).
final class FakeSyncServer: SyncTransport {
    var data: [String: [String: [String: Any]]] = [:]
    var pushes = 0
    var pushedRows: [(table: String, row: [String: Any])] = []
    private var tick: Int64 = SyncTime.micros("2026-10-30T10:00:00Z")!
    var failNext = false

    private func stamp() -> String {
        tick += 1_000
        // Microsecondes et « +00:00 », comme PostgREST.
        return SyncTime.iso(micros: tick + 123, digits: 6).replacingOccurrences(of: "Z", with: "+00:00")
    }

    func push(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        pushes += 1
        var out: [[String: Any]] = []
        for r in rows {
            pushedRows.append((table, r))
            let id = (r["id"] as! String).lowercased()
            let old = data[table]?[id]
            if let old, (r["updated_at"] as! String) < SyncTime.canonical(old["updated_at"] as! String)! {
                out.append(old)
                continue
            }
            var kept = old ?? [:]
            for (k, v) in r { kept[k] = v }
            kept["updated_at"] = (r["updated_at"] as! String).replacingOccurrences(of: "Z", with: "+00:00")
            kept["server_updated_at"] = stamp()
            if kept["deleted_at"] == nil { kept["deleted_at"] = NSNull() }
            data[table, default: [:]][id] = kept
            out.append(kept)
        }
        return out
    }

    func pull(table: String, since: String?, afterID: String?, limit: Int) async throws -> [[String: Any]] {
        if failNext { failNext = false; throw NSError(domain: "FakeSyncServer", code: 500) }
        func key(_ r: [String: Any]) -> (Int64, String) { (SyncTime.micros(r["server_updated_at"] as! String)!, r["id"] as! String) }
        let rows = (data[table] ?? [:]).values.filter { r in
            guard let since, let s = SyncTime.micros(since) else { return true }
            let (ts, id) = key(r)
            return ts > s || (ts == s && afterID != nil && id > afterID!)
        }.sorted { key($0) < key($1) }
        return Array(rows.prefix(limit))
    }
}

/// Une horloge qui avance d'une milliseconde à chaque lecture : les écritures de tous les appareils s'ordonnent.
final class SyncTestClock {
    var ms: Int64 = SyncTime.micros("2026-10-30T09:00:00Z")! / 1000
    func now() -> Date { ms += 1; return Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// Un appareil : sa base, son état de synchronisation, son moteur.
struct SyncTestDevice {
    let container: ModelContainer
    let store: SyncStateStore
    let engine: SyncEngine
    var context: ModelContext { ModelContext(container) }

    /// `keys` : l'appareil chiffre de bout en bout (`EncryptingSyncTransport` devant le serveur simulé).
    init(server: FakeSyncServer, clock: SyncTestClock, batch: Int = 200, keys: SyncCrypto.Keys? = nil, stats: SyncSkipStats = SyncSkipStats()) throws {
        container = try ModelContainer(for: PolymestreSchema.current,
                                       configurations: [ModelConfiguration(schema: PolymestreSchema.current, isStoredInMemoryOnly: true)])
        store = SyncStateStore(url: nil)
        let transport: SyncTransport = keys.map { EncryptingSyncTransport(inner: server, keys: $0, stats: stats) } ?? server
        engine = SyncEngine(container: container, transport: transport, store: store, batch: batch, clock: { clock.now() })
    }

    @discardableResult
    func sync(pull: Bool = true, accept: Bool = false) -> SyncEngine.Report {
        syncBlocking { try await engine.sync(pull: pull, acceptMassDeletion: accept) } ?? SyncEngine.Report()
    }

    func syncError(pull: Bool = true) -> Error? {
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        Task { do { _ = try await engine.sync(pull: pull) } catch { failure = error }; sem.signal() }
        sem.wait()
        return failure
    }
}

func syncBlocking<T>(_ body: @escaping () async throws -> T) -> T? {
    var result: T?
    let sem = DispatchSemaphore(value: 0)
    Task { result = try? await body(); sem.signal() }
    sem.wait()
    return result
}

func syncResults() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    do { try syncChecks(&results) } catch { results.append((false, "sync : une vérification a levé une erreur : \(error)")) }
    return results
}

func syncChecks(_ results: inout [(Bool, String)]) throws {
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }

    // MARK: Horodatages

    do {
        let a = SyncTime.micros("2026-10-30T10:00:00.123456+00:00")
        note(a == SyncTime.micros("2026-10-30T10:00:00.123456Z"), "sync : « +00:00 » et « Z » donnent le même instant")
        note(SyncTime.micros("2026-10-30T11:00:00+01:00") == SyncTime.micros("2026-10-30T10:00:00Z"), "sync : un décalage d'heure est appliqué")
        note(SyncTime.micros("2026-10-30 10:00:00+00") == SyncTime.micros("2026-10-30T10:00:00Z"), "sync : le format Postgres (espace, « +00 ») est lu")
        note(SyncTime.canonical("2026-10-30T10:00:00.123987+00:00") == "2026-10-30T10:00:00.123Z", "sync : les microsecondes sont tronquées à la milliseconde (comme toISOString)")
        note(SyncTime.canonical("2026-10-30T10:00:00+00:00") == "2026-10-30T10:00:00.000Z", "sync : une date sans fraction prend « .000 »")
        let d = Date(timeIntervalSince1970: 1_793_354_400.4567)
        let s = SyncTime.string(d)
        note(SyncTime.string(SyncTime.date(s)!) == s, "sync : date → texte → date → texte est stable (\(s))")
        note(SyncTime.string(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z", "sync : l'époque s'écrit 1970-01-01T00:00:00.000Z")
        note(SyncTime.string(Date(timeIntervalSince1970: -1.5)) == "1969-12-31T23:59:58.500Z", "sync : une date avant 1970 s'écrit juste")
        note(SyncTime.rewound("2026-10-30T10:02:00.000+00:00", seconds: 120) == "2026-10-30T10:00:00.000000Z", "sync : la marge de relecture recule le curseur de deux minutes (windows : rewind)")
        note(SyncTime.urlSafe("2026-10-30T10:02:00.5+00:00") == "2026-10-30T10:02:00.500000Z", "sync : un curseur n'a pas de « + » dans l'URL")
    }

    // MARK: Correspondance avec la migration (donc avec Windows)
    // (L'ancienne migration reste la description des champs du modèle ; en production ils vivent désormais
    // dans `payload`, chiffrés — voir SyncCryptoTests.swift et 20261103000000_sync_e2ee.sql.)

    do {
        let root = ProcessInfo.processInfo.environment["POLYMESTRE_ROOT"] ?? ""
        let path = root + "/supabase/migrations/20261030000000_user_data_sync.sql"
        if let sql = try? String(contentsOfFile: path, encoding: .utf8) {
            var sqlTables: [String: [String: String]] = [:]
            var current: String?
            for line in sql.split(separator: "\n", omittingEmptySubsequences: false) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("create table if not exists public.") {
                    current = l.replacingOccurrences(of: "create table if not exists public.", with: "").replacingOccurrences(of: " (", with: "")
                    sqlTables[current!] = [:]
                } else if l.hasPrefix(");") { current = nil }
                else if let t = current {
                    let parts = l.split(separator: " ", maxSplits: 2).map(String.init)
                    if parts.count >= 2 { sqlTables[t]![parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
                }
            }
            let reserved: Set<String> = ["id", "user_id", "updated_at", "deleted_at", "server_updated_at"]
            note(Set(sqlTables.keys) == Set(SyncSchema.tables.map(\.name)), "sync : les tables Swift sont exactement celles de la migration (\(sqlTables.count))")
            var allColumnsMatch = true, typesMatch = true
            var detail = ""
            for t in SyncSchema.tables {
                let sqlCols = Set(sqlTables[t.name, default: [:]].keys).subtracting(reserved)
                if sqlCols != Set(t.columns) { allColumnsMatch = false; detail += " \(t.name): \(sqlCols.symmetricDifference(Set(t.columns)))" }
                for (col, kind) in t.fieldKinds {
                    let sqlType = sqlTables[t.name]?[col] ?? ""
                    let expected: String
                    switch kind { case .text: expected = "text"; case .int: expected = "bigint"; case .double: expected = "double"; case .bool: expected = "boolean"; case .date: expected = "timestamptz" }
                    if sqlType != expected { typesMatch = false; detail += " \(t.name).\(col)=\(sqlType)≠\(expected)" }
                }
                for r in t.refInfos where sqlTables[t.name]?[r.column] != "uuid" { typesMatch = false; detail += " \(t.name).\(r.column) pas uuid" }
            }
            note(allColumnsMatch, "sync : chaque table a exactement les colonnes de la migration\(detail)")
            note(typesMatch, "sync : le type de chaque colonne (texte, entier, réel, booléen, date, uuid) est celui de la migration")
        } else {
            note(false, "sync : migration introuvable (POLYMESTRE_ROOT=\(root))")
        }
        note(SyncSchema.tables.count == 15, "sync : quinze tables synchronisées (15 @Model hors groupes et balise)")
        let linked = SyncSchema.tables.first { $0.name == "sync_linked_tasks" }
        note(linked?.columns.contains("task_updated_at") == true && linked?.columns.contains("updated_at") == false, "sync : LinkedTask.updatedAt va dans task_updated_at, pas dans updated_at")
        let sub = SyncSchema.tables.first { $0.name == "sync_sub_questions" }
        note(Set(sub?.refInfos.map(\.column) ?? []) == ["exercise_id", "parent_id"], "sync : une sous-question a exercise_id et parent_id")
        let ss = SyncSchema.tables.first { $0.name == "sync_study_sessions" }
        note(ss?.refInfos.first { $0.column == "exercise_id" }?.onDelete == .nullify && ss?.refInfos.first { $0.column == "course_id" }?.onDelete == .cascade,
             "sync : règles de suppression d'une session : cours en cascade, exercice mis à nul")
    }

    // MARK: Mot de passe (PUT /auth/v1/user)

    do {
        note(SupabasePasswordUpdate.method == "PUT" && SupabasePasswordUpdate.path == "/auth/v1/user", "mot de passe : PUT /auth/v1/user")
        let body = SupabasePasswordUpdate.body(password: "s3cret é\"x")
        let decoded = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        note(decoded == ["password": "s3cret é\"x"], "mot de passe : le corps est {\"password\": …} et seulement cela")
        note(SupabasePasswordUpdate.validate("abc", confirmation: "abc") == .tooShort, "mot de passe : moins de 6 caractères refusé")
        note(SupabasePasswordUpdate.validate("abcdef", confirmation: "abcdeg") == .mismatch, "mot de passe : deux saisies différentes refusées")
        note(SupabasePasswordUpdate.validate("abcdef", confirmation: "abcdef") == nil, "mot de passe : 6 caractères identiques acceptés")
        let apple: [String: Any] = ["app_metadata": ["provider": "apple", "providers": ["apple"]], "identities": [["provider": "apple"]]]
        note(SupabasePasswordUpdate.providers(in: apple) == ["apple"], "mot de passe : un compte Apple est reconnu (sans doublon)")
        let both: [String: Any] = ["app_metadata": ["provider": "email", "providers": ["email", "apple"]]]
        note(SupabasePasswordUpdate.providers(in: both) == ["email", "apple"], "mot de passe : plusieurs fournisseurs lus")
        note(SupabasePasswordUpdate.providers(in: [:]).isEmpty, "mot de passe : fournisseurs inconnus → liste vide")
        note(SupabasePasswordUpdate.message(forStatus: 422, body: "{\"error_code\":\"same_password\"}").contains("déjà"), "mot de passe : même mot de passe → message clair")
    }

    // MARK: Google (OAuth PKCE)

    do {
        note(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
             "google : le vecteur de la RFC 7636 (annexe B) donne le bon défi S256")
        let v = OAuthPKCE.makeVerifier()
        note(v.count == 43 && v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && v != OAuthPKCE.makeVerifier(), "google : un verifier tiré a 43 caractères permis et change à chaque fois")
        let url = OAuthPKCE.authorizeURL(base: URL(string: "https://x.supabase.co")!, challenge: "CHAL")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        note(url.path == "/auth/v1/authorize" && q("provider") == "google" && q("redirect_to") == "polymestre://auth-callback"
             && q("code_challenge") == "CHAL" && q("code_challenge_method") == "s256", "google : l'adresse d'autorisation porte provider, rappel et défi S256")
        let link = OAuthPKCE.authorizeURL(base: URL(string: "https://x.supabase.co")!, challenge: "C", link: true, skipRedirect: true)!
        note(link.path == "/auth/v1/user/identities/authorize" && link.query?.contains("skip_http_redirect=true") == true, "google : lier une identité passe par /user/identities/authorize")
        note(OAuthPKCE.parseCallback(URL(string: "polymestre://auth-callback?code=abc123")!) == .code("abc123"), "google : le retour donne son code")
        note(OAuthPKCE.parseCallback(URL(string: "polymestre://auth-callback?error=access_denied&error_description=Nope")!) == .error("Nope"), "google : le retour en erreur (requête) est lu")
        note(OAuthPKCE.parseCallback(URL(string: "polymestre://auth-callback#error_code=400&error_description=bad")!) == .error("bad"), "google : le retour en erreur (fragment) est lu")
        note(OAuthPKCE.parseCallback(URL(string: "https://x.supabase.co/?code=1")!) == nil && OAuthPKCE.parseCallback(URL(string: "polymestre://auth-callback")!) == nil, "google : ce qui n'est pas notre retour est ignoré")
        let body = OAuthPKCE.exchangeBody(code: "C1", verifier: "V1").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        note(body == ["auth_code": "C1", "code_verifier": "V1"] && OAuthPKCE.exchangePath == "/auth/v1/token" && OAuthPKCE.exchangeQuery.first?.value == "pkce", "google : la requête d'échange est POST /auth/v1/token?grant_type=pkce {auth_code, code_verifier}")
        note(OAuthPKCE.message(status: 400, body: "{\"msg\":\"Unsupported provider: provider is not enabled\"}") == "La connexion Google n'est pas encore activée sur le serveur.", "google : fournisseur éteint → message clair")
        note(OAuthPKCE.message(status: 400, body: "Manual linking is disabled", link: true) == OAuthPKCE.linkDisabledMessage, "google : liaison manuelle éteinte → message clair")
        note(OAuthPKCE.callbackMessage("Unsupported provider: provider is not enabled").contains("pas encore activée"), "google : le retour en erreur est traduit")
    }

    // MARK: Cas d'usage

    func fill(_ device: SyncTestDevice) throws -> (Course, ExerciseSeries, Exercise) {
        let ctx = device.context
        let term = AcademicTerm(year: 2026, season: .autumn, startDate: Date(timeIntervalSince1970: 1_790_000_000.123), endDate: Date(timeIntervalSince1970: 1_800_000_000), totalWeeks: 14, name: "Automne 2026")
        ctx.insert(term)
        let course = Course(code: "MATH-101", name: "Analyse I", credits: 8)
        course.term = term
        course.weeklySelfStudyHours = 4.5
        course.isTracked = true
        ctx.insert(course)
        let series = ExerciseSeries(course: course, seriesNumber: 3)
        ctx.insert(series)
        let exercise = Exercise(series: series, exerciseNumber: "3.1", title: "Limites")
        exercise.doneAt = Date(timeIntervalSince1970: 1_791_000_000.5)
        exercise.score = 7.5
        ctx.insert(exercise)
        let question = SubQuestion(exercise: exercise, label: "a)")
        ctx.insert(question)
        let child = SubQuestion(parent: question, label: "i)")
        ctx.insert(child)
        let session = StudySession(course: course, durationSeconds: 600, exercise: exercise)
        ctx.insert(session)
        let item = TheoryItem(course: course, sectionNumber: 1, number: "1.1", title: "Suites")
        ctx.insert(item)
        try ctx.save()
        return (course, series, exercise)
    }

    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let mac = try SyncTestDevice(server: server, clock: clock)
        let pc = try SyncTestDevice(server: server, clock: clock)
        _ = try fill(mac)
        let r1 = mac.sync()
        note(r1.pushed == 8, "sync : un premier passage envoie tout ce qu'il y a (8 lignes, obtenu \(r1.pushed))")
        let course = server.data["sync_courses"]?.values.first
        note(course?["code"] as? String == "MATH-101" && course?["credits"] as? Double == 8 && course?["is_tracked"] as? Bool == true, "sync : le corps envoyé porte les colonnes snake_case, booléens et réels natifs")
        note(course?["weekly_self_study_hours"] as? Double == 4.5 && course?["term_id"] is String, "sync : l'optionnel renseigné et la relation partent")
        let sentRow = server.pushedRows.first { $0.table == "sync_courses" }?.row
        note((sentRow?["id"] as? String) == (sentRow?["id"] as? String)?.lowercased() && (sentRow?["term_id"] as? String)?.lowercased() == sentRow?["term_id"] as? String, "sync : identifiants en minuscules, comme Postgres et Windows")
        note((sentRow?["updated_at"] as? String)?.hasSuffix("Z") == true && (sentRow?["deleted_at"] is NSNull), "sync : updated_at en ISO « Z », deleted_at nul sur une ligne vivante")
        let term = server.data["sync_academic_terms"]?.values.first
        note(term?["start_date"] as? String == SyncTime.string(Date(timeIntervalSince1970: 1_790_000_000.123)), "sync : une date part à la milliseconde, en ISO « Z »")
        let exRow = server.data["sync_exercises"]?.values.first
        note(exRow?["score"] as? Double == 7.5 && exRow?["max_score"] is NSNull && exRow?["done_at"] is String, "sync : optionnel absent → null, présent → valeur")

        let before = server.pushes
        let r2 = mac.sync()
        note(r2.pushed == 0 && server.pushes == before, "sync : un second passage sans modification n'envoie rien (pas d'écho)")

        let r3 = pc.sync()
        note(r3.pulled >= 8, "sync : l'autre appareil lit les lignes (\(r3.pulled))")
        let ctx = pc.context
        let courses = (try? ctx.fetch(FetchDescriptor<Course>())) ?? []
        note(courses.count == 1 && courses[0].code == "MATH-101" && courses[0].credits == 8 && courses[0].weeklySelfStudyHours == 4.5 && courses[0].isTracked, "sync : le cours arrive avec ses champs")
        note(courses.first?.term?.name == "Automne 2026", "sync : la relation cours → semestre est rétablie")
        note(courses.first?.series.first?.exercises.first?.subQuestions.count == 1 && courses.first?.series.first?.exercises.first?.score == 7.5, "sync : séries, exercices et sous-questions suivent les relations")
        let ex = (try? ctx.fetch(FetchDescriptor<Exercise>()))?.first
        note(ex?.doneAt == SyncTime.date(SyncTime.string(Date(timeIntervalSince1970: 1_791_000_000.5))), "sync : la date optionnelle arrive à la milliseconde")
        note((try? ctx.fetch(FetchDescriptor<StudySession>()))?.first?.exercise?.exerciseNumber == "3.1", "sync : la session retrouve son exercice")
        let pushesAfter = server.pushes
        let r4 = pc.sync()
        note(r4.pushed == 0 && server.pushes == pushesAfter, "sync : ce qui vient d'être lu n'est pas renvoyé (pas d'écho)")

        // Plus récent gagne, des deux côtés.
        let ctxP = pc.context
        let cP = try ctxP.fetch(FetchDescriptor<Course>())[0]
        cP.name = "ancienne (pc)"
        try ctxP.save()
        pc.sync(pull: false)            // pc détecte et envoie l'ancienne
        let ctxM = mac.context
        let cM = try ctxM.fetch(FetchDescriptor<Course>())[0]
        cM.name = "récente (mac)"
        try ctxM.save()
        mac.sync()                       // mac envoie une écriture plus récente
        pc.sync()
        let pcName = (try pc.context.fetch(FetchDescriptor<Course>()))[0].name
        let macName = (try mac.context.fetch(FetchDescriptor<Course>()))[0].name
        note(pcName == "récente (mac)" && macName == "récente (mac)", "sync : la modification la plus récente gagne sur les deux appareils (\(pcName) / \(macName))")
        note(server.data["sync_courses"]?.values.first?["name"] as? String == "récente (mac)", "sync : et sur le serveur")

        // Une ancienne écriture arrivant en retard est refusée par le serveur : l'appareil adopte la version gardée.
        let stale = try SyncTestDevice(server: server, clock: clock)
        _ = stale.sync()
        let cS = try stale.context.fetch(FetchDescriptor<Course>())[0]
        let staleCtx = stale.context
        let cS2 = try staleCtx.fetch(FetchDescriptor<Course>())[0]
        cS2.name = "tardive"
        try staleCtx.save()
        _ = cS
        server.data["sync_courses"]![server.data["sync_courses"]!.keys.first!]!["updated_at"] = "2099-01-01T00:00:00+00:00"
        server.data["sync_courses"]![server.data["sync_courses"]!.keys.first!]!["name"] = "gardée"
        stale.sync(pull: false)
        let adopted = try stale.context.fetch(FetchDescriptor<Course>())[0].name
        note(adopted == "gardée", "sync : une écriture périmée est refusée, l'appareil adopte la version du serveur (\(adopted))")
    }

    // Local plus récent non écrasé à la lecture.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        let c = Course(code: "X", name: "v1")
        ctx.insert(c)
        try ctx.save()
        a.sync()
        let id = c.id.uuidString.lowercased()
        server.data["sync_courses"]![id]!["name"] = "serveur"
        server.data["sync_courses"]![id]!["updated_at"] = "2026-10-30T09:00:00.000+00:00"
        server.data["sync_courses"]![id]!["server_updated_at"] = "2026-10-30T10:30:00.000000+00:00"
        let ctx2 = a.context
        let c2 = try ctx2.fetch(FetchDescriptor<Course>())[0]
        c2.name = "locale"
        try ctx2.save()
        let report = a.sync()
        let name = try a.context.fetch(FetchDescriptor<Course>())[0].name
        note(report.keptLocal == 1 && name == "locale", "sync : une modification locale plus récente que le serveur n'est pas écrasée à la lecture")
        note(server.data["sync_courses"]![id]!["name"] as? String == "locale", "sync : … et elle part au serveur")
    }

    // Suppression : cascade, mise à nul, pierres tombales.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let b = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        let course = Course(code: "PHYS", name: "Physique")
        ctx.insert(course)
        let other = Course(code: "OTHER", name: "Autre")
        ctx.insert(other)
        let series = ExerciseSeries(course: course, seriesNumber: 1)
        ctx.insert(series)
        let ex = Exercise(series: series, exerciseNumber: "1.1")
        ctx.insert(ex)
        let q1 = SubQuestion(exercise: ex, label: "a)")
        ctx.insert(q1)
        let q2 = SubQuestion(parent: q1, label: "i)")
        ctx.insert(q2)
        let session = StudySession(course: other, durationSeconds: 600, exercise: ex)
        ctx.insert(session)
        try ctx.save()
        a.sync()
        b.sync()

        let ctxD = a.context
        let victim = try ctxD.fetch(FetchDescriptor<Course>()).first { $0.code == "PHYS" }!
        ctxD.delete(victim)
        try ctxD.save()
        let before = server.pushedRows.count
        a.sync()
        let tombs = server.pushedRows.dropFirst(before).filter { !($0.row["deleted_at"] is NSNull) }
        note(tombs.count == 5, "sync : supprimer un cours envoie 5 pierres tombales : cours, série, exercice, 2 sous-questions (obtenu \(tombs.count))")
        note(tombs.allSatisfy { Set($0.row.keys) == ["id", "updated_at", "deleted_at"] }, "sync : une pierre tombale ne porte que id, updated_at, deleted_at")
        let sess = server.data["sync_study_sessions"]?.values.first
        note(sess?["exercise_id"] is NSNull && sess?["deleted_at"] is NSNull, "sync : la session de l'autre cours reste, sans exercice (mise à nul)")
        note(server.data["sync_courses"]?.values.filter { !($0["deleted_at"] is NSNull) }.count == 1, "sync : le cours supprimé est une pierre tombale côté serveur")

        b.sync()
        let ctxB = b.context
        let leftovers = try ctxB.fetch(FetchDescriptor<Exercise>()).count + ctxB.fetch(FetchDescriptor<ExerciseSeries>()).count + ctxB.fetch(FetchDescriptor<SubQuestion>()).count
        note(leftovers == 0, "sync : sur l'autre appareil, la suppression emporte séries, exercices et sous-questions")
        note(try ctxB.fetch(FetchDescriptor<Course>()).map(\.code) == ["OTHER"], "sync : … et laisse l'autre cours")
        let sessB = try ctxB.fetch(FetchDescriptor<StudySession>())
        note(sessB.count == 1 && sessB[0].exercise == nil, "sync : … et la session perd son exercice")

        // Pas d'écho : b n'a rien à renvoyer.
        let p = server.pushes
        b.sync()
        note(server.pushes == p, "sync : appliquer des suppressions distantes n'en renvoie aucune de plus d'une fois")
    }

    // Orphelin ajouté hors ligne dans une série supprimée ailleurs.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let b = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        let s = ExerciseSeries(seriesNumber: 2)
        ctx.insert(s)
        try ctx.save()
        a.sync(); b.sync()

        let ctxB = b.context
        let sB = try ctxB.fetch(FetchDescriptor<ExerciseSeries>())[0]
        let e = Exercise(series: sB, exerciseNumber: "9")
        ctxB.insert(e)
        try ctxB.save()                  // b, hors ligne
        let ctxA = a.context
        ctxA.delete(try ctxA.fetch(FetchDescriptor<ExerciseSeries>())[0])
        try ctxA.save()
        a.sync()
        let eid = e.id.uuidString.lowercased()
        b.sync()                         // b lit la suppression de la série : son exercice la suit
        note(try b.context.fetch(FetchDescriptor<Exercise>()).isEmpty, "sync : un exercice ajouté hors ligne dans une série supprimée ailleurs disparaît aussi")
        a.sync()
        note(server.data["sync_exercises"]?[eid]?["deleted_at"] is String, "sync : et sa pierre tombale arrive au serveur")
    }

    // Lecture par pages.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock, batch: 7)
        let b = try SyncTestDevice(server: server, clock: clock, batch: 7)
        let ctx = a.context
        for k in 0..<50 { ctx.insert(Mistake(exercise: nil, kind: .method, summary: "erreur \(k)")) }
        try ctx.save()
        let ra = a.sync()
        note(ra.pushed == 50 && server.pushes >= 8, "sync : cinquante lignes partent par lots de sept (\(server.pushes) envois)")
        b.sync()
        note(try b.context.fetch(FetchDescriptor<Mistake>()).count == 50, "sync : lues par pages sans rien perdre")
        let again = b.sync()
        note(again.keptLocal == 0 && again.pushed == 0, "sync : relire la marge ne change rien")
    }

    // Contenu identique déjà sur le serveur (iCloud a apporté les mêmes données) : adopté, pas renvoyé.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        let id = UUID()
        let c = Course(id: id, code: "CS-250", name: "Algo", credits: 6)
        ctx.insert(c)
        try ctx.save()
        a.sync()
        // b reçoit le même cours par iCloud (même identifiant, même contenu), sans jamais avoir synchronisé.
        let b = try SyncTestDevice(server: server, clock: clock)
        let ctxB = b.context
        let cb = Course(id: id, code: "CS-250", name: "Algo", credits: 6)
        ctxB.insert(cb)
        try ctxB.save()
        let p = server.pushes
        let r = b.sync()
        note(r.pushed == 0 && server.pushes == p, "sync : un contenu identique déjà au serveur est adopté, pas renvoyé (iCloud + Supabase sans écho)")
    }

    // Garde-fou de suppression massive.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        for k in 0..<40 { ctx.insert(Mistake(exercise: nil, kind: .slip, summary: "m\(k)")) }
        try ctx.save()
        a.sync()
        let wipe = a.context
        for m in try wipe.fetch(FetchDescriptor<Mistake>()) { wipe.delete(m) }
        try wipe.save()
        let error = a.syncError()
        note(error is SyncEngine.Failure, "sync : la disparition de 40 éléments sur 40 est retenue, pas propagée")
        note(server.data["sync_mistakes"]?.values.allSatisfy { $0["deleted_at"] is NSNull } == true, "sync : … rien n'est supprimé au serveur")
        a.sync(accept: true)
        note(server.data["sync_mistakes"]?.values.allSatisfy { $0["deleted_at"] is String } == true, "sync : … confirmée, la suppression part")
    }

    // Deux passes lancées ensemble n'en font qu'une.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        ctx.insert(Course(code: "X", name: "x"))
        try ctx.save()
        let reports = syncBlocking { () -> [SyncEngine.Report] in
            async let one = try a.engine.sync(pull: true)
            async let two = try a.engine.sync(pull: true)
            return try await [one, two]
        }
        note(reports?.count == 2 && reports![0] == reports![1] && server.data["sync_courses"]?.count == 1, "sync : deux synchronisations lancées ensemble n'en font qu'une")
    }

    // Une panne réseau en lecture laisse l'état intact et la passe suivante rattrape.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let a = try SyncTestDevice(server: server, clock: clock)
        let b = try SyncTestDevice(server: server, clock: clock)
        let ctx = a.context
        ctx.insert(Course(code: "Z", name: "z"))
        try ctx.save()
        a.sync()
        server.failNext = true
        note(b.syncError() != nil, "sync : une erreur serveur remonte")
        b.sync()
        note(try b.context.fetch(FetchDescriptor<Course>()).count == 1, "sync : la passe suivante rattrape")
    }

    // La relation lue avant sa cible est rétablie.
    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let courseID = UUID()
        server.data["sync_exams"] = [UUID().uuidString.lowercased(): [
            "id": UUID().uuidString.lowercased(), "title": "Examen", "kind_raw": "exam", "course_id": courseID.uuidString.lowercased(),
            "date": "2026-12-01T08:00:00+00:00", "updated_at": "2026-10-30T09:00:00+00:00", "deleted_at": NSNull(),
            "server_updated_at": "2026-10-30T10:00:00.000001+00:00"]]
        let b = try SyncTestDevice(server: server, clock: clock)
        b.sync()
        let exam = try b.context.fetch(FetchDescriptor<Exam>())
        note(exam.count == 1 && exam[0].course == nil, "sync : un examen dont le cours n'est pas encore arrivé s'ouvre sans cours")
        let p = server.pushes
        b.sync()
        note(server.pushes == p, "sync : … sans renvoyer la relation perdue au serveur")
        server.data["sync_courses"] = [courseID.uuidString.lowercased(): [
            "id": courseID.uuidString.lowercased(), "code": "C", "name": "n", "updated_at": "2026-10-30T09:00:00+00:00", "deleted_at": NSNull(),
            "server_updated_at": "2026-10-30T10:05:00.000001+00:00"]]
        b.sync()
        let exam2 = try b.context.fetch(FetchDescriptor<Exam>())
        note(exam2.first?.course?.code == "C", "sync : … et la relation se rétablit quand le cours arrive")
    }

}
