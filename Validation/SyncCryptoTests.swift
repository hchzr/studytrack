import Foundation
import SwiftData
import CryptoKit

// Contrôles du chiffrement de bout en bout de la synchronisation (SyncCrypto.swift,
// SyncEncryption.swift, SyncPairing.swift) : les vecteurs communs avec Windows
// (supabase/e2ee-vectors.json, relus par windows/tests/domain/syncCrypto.test.ts), les
// propriétés (aller-retour, AAD, mauvaise clé, clé de secours), le moteur de synchronisation
// derrière le chiffrement, et l'appairage par un relais en mémoire.

/// Le relais d'appairage en mémoire, avec les règles de relay/src/index.ts : un salon par nom de
/// canal, les messages `pair` (≤ 4 Ko) sont transmis aux autres sockets du salon, rien n'est gardé.
/// `log` garde tout ce que le relais a vu, pour vérifier ce qu'il ne voit pas.
final class MemoryPairRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [String: [MemoryPairSocket]] = [:]
    private var transcript: [String] = []
    private var channelNames: [String] = []
    private var open = 0

    var log: [String] { lock.lock(); defer { lock.unlock() }; return transcript }
    var channels: [String] { lock.lock(); defer { lock.unlock() }; return channelNames }
    var openSockets: Int { lock.lock(); defer { lock.unlock() }; return open }

    /// `redirect` : tout le monde atterrit dans ce salon (un mauvais code qui tombe sur le bon canal).
    func factory(redirect: String? = nil) -> SyncPairSocketFactory {
        { [self] channel in connect(redirect ?? channel) }
    }

    private func connect(_ channel: String) -> SyncPairSocket {
        let socket = MemoryPairSocket(relay: self, channel: channel)
        lock.lock()
        rooms[channel, default: []].append(socket)
        channelNames.append(channel)
        open += 1
        lock.unlock()
        return socket
    }

    fileprivate func deliver(_ text: String, from sender: MemoryPairSocket, channel: String) {
        guard text.utf8.count <= 4096 else { return }
        lock.lock()
        transcript.append(text)
        let others = (rooms[channel] ?? []).filter { $0 !== sender }
        lock.unlock()
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], object["t"] as? String == "pair" else { return }
        for other in others { DispatchQueue.global().async { other.onMessage?(text) } }
    }

    fileprivate func remove(_ socket: MemoryPairSocket, channel: String) {
        lock.lock()
        rooms[channel]?.removeAll { $0 === socket }
        open -= 1
        lock.unlock()
    }
}

final class MemoryPairSocket: SyncPairSocket, @unchecked Sendable {
    var onOpen: (() -> Void)? {
        didSet { if let f = onOpen, !opened { opened = true; DispatchQueue.global().async(execute: f) } }
    }
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let relay: MemoryPairRelay
    private let channel: String
    private var opened = false
    private var closed = false

    init(relay: MemoryPairRelay, channel: String) {
        self.relay = relay
        self.channel = channel
    }

    func send(_ text: String) { if !closed { relay.deliver(text, from: self, channel: channel) } }
    func close() {
        guard !closed else { return }
        closed = true
        relay.remove(self, channel: channel)
    }
}

/// Les états vus par l'hôte, rangés sous verrou (le rappel arrive sur n'importe quel fil).
final class PairStateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncPairingHost.State] = []
    func add(_ s: SyncPairingHost.State) { lock.lock(); items.append(s); lock.unlock() }
    var states: [SyncPairingHost.State] { lock.lock(); defer { lock.unlock() }; return items }
}

func syncCryptoResults() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    do { try syncCryptoChecks(&results) } catch { results.append((false, "sync chiffrée : une vérification a levé une erreur : \(error)")) }
    return results
}

func syncCryptoChecks(_ results: inout [(Bool, String)]) throws {
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }
    func hex(_ d: Data) -> String { SyncCrypto.hex(d) }
    func bytes(_ s: String) -> Data { SyncCrypto.data(hex: s) ?? Data() }
    func throwsError<T>(_ body: () throws -> T) -> Bool { (try? body()) == nil }

    // MARK: Vecteurs communs avec Windows

    let root = ProcessInfo.processInfo.environment["STUDYTRACK_ROOT"] ?? ""
    guard let vectorData = try? Data(contentsOf: URL(fileURLWithPath: root + "/supabase/e2ee-vectors.json")),
          let V = try? JSONSerialization.jsonObject(with: vectorData) as? [String: Any],
          let row = V["row"] as? [String: Any], let pairing = V["pairing"] as? [String: Any],
          let fields = row["fields"] as? [String: Any] else {
        note(false, "sync chiffrée : supabase/e2ee-vectors.json introuvable (STUDYTRACK_ROOT=\(root))")
        return
    }
    let ak = bytes(V["accountKey"] as! String)
    let keys = try SyncCrypto.keys(for: ak)
    note(hex(keys.dataKey) == V["dataKey"] as? String, "sync chiffrée : vecteur — la clé du compte donne la dataKey de Windows")
    note(keys.keyID == V["keyId"] as? String, "sync chiffrée : vecteur — … et le keyId (HKDF « key-id », 16 octets)")

    // Le JSON des champs : les nombres entiers valent des entiers (JSONSerialization rend des NSNumber ;
    // on ne reconstitue donc que des types que SyncTable.encode produit).
    var typed: [String: Any] = [:]
    for (k, v) in fields {
        switch v {
        case is NSNull: typed[k] = NSNull()
        case let s as String: typed[k] = s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { typed[k] = n.boolValue }
            else if n.doubleValue == n.doubleValue.rounded(), !n.stringValue.contains(".") { typed[k] = n.intValue }
            else { typed[k] = n.doubleValue }
        default: break
        }
    }
    note(SyncCrypto.canonicalJSON(typed) == row["plaintext"] as? String, "sync chiffrée : vecteur — le JSON canonique est celui de Windows (clés triées, échappements)")
    let table = row["table"] as! String, rowID = row["id"] as! String
    note(SyncCrypto.rowAAD(table: table, id: rowID) == Data((row["aad"] as! String).utf8), "sync chiffrée : vecteur — AAD « <table>/<id en minuscules>/v1 »")
    let sealed = try SyncCrypto.sealRow(dataKey: keys.dataKey, table: table, id: rowID, fields: typed, nonce: bytes(row["nonce"] as! String))
    note(hex(sealed) == row["payload"] as? String, "sync chiffrée : vecteur — ligne figée + nonce figé → payload identique octet pour octet")
    note(SyncCrypto.bytea(sealed) == row["bytea"] as? String, "sync chiffrée : vecteur — bytea « \\x… »")
    let opened = try SyncCrypto.openRow(dataKey: keys.dataKey, table: table, id: rowID, box: bytes(row["payload"] as! String))
    note(opened["name"] as? String == fields["name"] as? String && opened["credits"] as? Double == 7.5 && opened["is_active"] as? Bool == true && opened["notes"] is NSNull,
         "sync chiffrée : vecteur — le payload de Windows s'ouvre ici")

    note(SyncCrypto.encodeRecoveryKey(ak) == V["recoveryKey"] as? String, "sync chiffrée : vecteur — clé de secours identique (Crockford + somme de contrôle)")
    note((try? SyncCrypto.decodeRecoveryKey(V["recoveryKey"] as! String)) == ak, "sync chiffrée : vecteur — … et relue")
    let S = bytes(pairing["secret"] as! String)
    note(SyncCrypto.encodePairingCode(S) == pairing["code"] as? String && SyncCrypto.pairingQRText(S) == pairing["qr"] as? String, "sync chiffrée : vecteur — code d'appairage et texte du QR")
    note(SyncCrypto.parsePairingInput(pairing["qr"] as! String) == S, "sync chiffrée : vecteur — le texte du QR se relit")
    note(SyncCrypto.pairChannel(S) == pairing["channel"] as? String, "sync chiffrée : vecteur — nom du canal du relais")
    let eA = try SyncCrypto.Ephemeral(privateKey: bytes(pairing["privateA"] as! String))
    let eB = try SyncCrypto.Ephemeral(privateKey: bytes(pairing["privateB"] as! String))
    note(hex(eA.publicKey) == pairing["publicA"] as? String && hex(eB.publicKey) == pairing["publicB"] as? String, "sync chiffrée : vecteur — clés publiques X25519 identiques")
    let kA = try SyncCrypto.pairKey(mine: eA, theirPublic: eB.publicKey, secret: S, pubA: eA.publicKey, pubB: eB.publicKey)
    let kB = try SyncCrypto.pairKey(mine: eB, theirPublic: eA.publicKey, secret: S, pubA: eA.publicKey, pubB: eB.publicKey)
    note(hex(kA) == pairing["key"] as? String && kA == kB, "sync chiffrée : vecteur — la clé d'appairage k (ECDH ‖ S) est celle de Windows, des deux côtés")
    let sealedAK = try SyncCrypto.sealAccountKey(kA, accountKey: ak, nonce: bytes(pairing["nonceAK"] as! String))
    note(hex(sealedAK) == pairing["sealedAccountKey"] as? String, "sync chiffrée : vecteur — la clé du compte scellée pour l'appairage")
    note((try? SyncCrypto.openAccountKey(kB, box: bytes(pairing["sealedAccountKey"] as! String))) == ak, "sync chiffrée : vecteur — … s'ouvre avec k")
    let sealedOK = try SyncCrypto.sealOK(kA, nonce: bytes(pairing["nonceOk"] as! String))
    note(hex(sealedOK) == pairing["sealedOk"] as? String && SyncCrypto.openOK(kA, box: sealedOK), "sync chiffrée : vecteur — la confirmation « ok »")

    // MARK: Propriétés

    do {
        let k1 = try SyncCrypto.keys(for: SyncCrypto.newAccountKey()), k2 = try SyncCrypto.keys(for: SyncCrypto.newAccountKey())
        let f: [String: Any] = ["name": "Analyse I", "credits": 7.5, "is_active": true, "notes": NSNull(), "n": 3]
        let a = try SyncCrypto.sealRow(dataKey: k1.dataKey, table: "sync_courses", id: "AbC-1", fields: f)
        let b = try SyncCrypto.sealRow(dataKey: k1.dataKey, table: "sync_courses", id: "AbC-1", fields: f)
        note(a != b, "sync chiffrée : deux scellements du même contenu diffèrent (nonce aléatoire)")
        let back = try SyncCrypto.openRow(dataKey: k1.dataKey, table: "sync_courses", id: "abc-1", box: a)
        note(back["name"] as? String == "Analyse I" && back["credits"] as? Double == 7.5 && back["n"] as? Int == 3, "sync chiffrée : aller-retour (la casse de l'id ne compte pas)")
        note(throwsError { try SyncCrypto.openRow(dataKey: k1.dataKey, table: "sync_courses", id: "other", box: a) }, "sync chiffrée : une ligne déplacée vers un autre id ne s'ouvre pas")
        note(throwsError { try SyncCrypto.openRow(dataKey: k1.dataKey, table: "sync_exams", id: "AbC-1", box: a) }, "sync chiffrée : … ni vers une autre table")
        note(throwsError { try SyncCrypto.openRow(dataKey: k2.dataKey, table: "sync_courses", id: "AbC-1", box: a) }, "sync chiffrée : mauvaise clé : refus")
        var tampered = a; tampered[tampered.startIndex + 20] ^= 1
        note(throwsError { try SyncCrypto.openRow(dataKey: k1.dataKey, table: "sync_courses", id: "AbC-1", box: tampered) }, "sync chiffrée : un octet modifié : refus")
        note(throwsError { try SyncCrypto.openRow(dataKey: k1.dataKey, table: "sync_courses", id: "AbC-1", box: a.prefix(20)) }, "sync chiffrée : boîte trop courte : refus")
        note(SyncCrypto.data(fromBytea: "\\x01ff") == Data([1, 255]) && SyncCrypto.data(fromBytea: "01ff") == nil && SyncCrypto.data(fromBytea: "\\x0") == nil && SyncCrypto.data(fromBytea: NSNull()) == nil, "sync chiffrée : bytea strict")
        note(SyncCrypto.canonicalJSON(["b": 4.0, "a": "x\"\\\n\u{01}", "é": NSNull()]) == "{\"a\":\"x\\\"\\\\\\n\\u0001\",\"b\":4,\"é\":null}", "sync chiffrée : JSON canonique (4.0 s'écrit 4, contrôles en \\u00xx)")
    }

    do {
        let ak = SyncCrypto.newAccountKey()
        let text = SyncCrypto.encodeRecoveryKey(ak)
        let parts = text.split(separator: "-")
        note(text.replacingOccurrences(of: "-", with: "").count == 54 && parts.dropLast().allSatisfy { $0.count == 4 } && parts.last?.count == 2, "sync chiffrée : clé de secours — 54 caractères par groupes de 4")
        note((try? SyncCrypto.decodeRecoveryKey(text)) == ak, "sync chiffrée : clé de secours — aller-retour")
        note((try? SyncCrypto.decodeRecoveryKey(text.lowercased().replacingOccurrences(of: "-", with: " "))) == ak, "sync chiffrée : clé de secours — minuscules et espaces tolérés")
        note((try? SyncCrypto.decodeRecoveryKey(text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l"))) == ak, "sync chiffrée : clé de secours — O/0 et I,l/1 confondus tolérés")
        var chars = Array(text)
        let i = chars.indices.first { $0 > 3 && chars[$0] != "-" }!
        chars[i] = chars[i] == "7" ? "8" : "7"
        var checksumError = false
        do { _ = try SyncCrypto.decodeRecoveryKey(String(chars)) } catch SyncCrypto.RecoveryFailure.checksum { checksumError = true } catch {}
        note(checksumError, "sync chiffrée : clé de secours — une faute de frappe est détectée (somme de contrôle)")
        var formatError = false
        do { _ = try SyncCrypto.decodeRecoveryKey(String(text.prefix(30))) } catch SyncCrypto.RecoveryFailure.format { formatError = true } catch {}
        note(formatError, "sync chiffrée : clé de secours — trop courte : erreur de format")
        let s = SyncCrypto.newPairingSecret()
        let code = SyncCrypto.encodePairingCode(s)
        let flat = code.replacingOccurrences(of: "-", with: "")
        note(flat.count == 26 && SyncCrypto.decodePairingCode(code) == s && SyncCrypto.decodePairingCode(String(code.dropLast())) == nil, "sync chiffrée : code d'appairage — 26 caractères, aller-retour")
        note(SyncCrypto.decodePairingCode(String(flat.prefix(25)) + (flat.last == "Z" ? "Y" : "Z")) == nil, "sync chiffrée : code d'appairage — bits de remplissage non nuls refusés")
        let eA = try SyncCrypto.Ephemeral(), eB = try SyncCrypto.Ephemeral()
        let k1 = try SyncCrypto.pairKey(mine: eA, theirPublic: eB.publicKey, secret: SyncCrypto.newPairingSecret(), pubA: eA.publicKey, pubB: eB.publicKey)
        let k2 = try SyncCrypto.pairKey(mine: eA, theirPublic: eB.publicKey, secret: SyncCrypto.newPairingSecret(), pubA: eA.publicKey, pubB: eB.publicKey)
        note(k1 != k2 && throwsError { try SyncCrypto.openAccountKey(k2, box: try SyncCrypto.sealAccountKey(k1, accountKey: ak)) }, "sync chiffrée : un autre secret S donne une autre clé d'appairage")
        note(!SyncCrypto.openOK(k1, box: try SyncCrypto.sealAccountKey(k1, accountKey: ak)), "sync chiffrée : la boîte de la clé n'est pas la confirmation")
    }

    // MARK: Le moteur derrière le chiffrement

    func store(_ ctx: ModelContext) throws {
        let course = Course(code: "MATH-101", name: "Analyse I", credits: 8)
        course.weeklySelfStudyHours = 4.5
        ctx.insert(course)
        let series = ExerciseSeries(course: course, seriesNumber: 3)
        ctx.insert(series)
        let exercise = Exercise(series: series, exerciseNumber: "3.1", title: "Limites")
        exercise.score = 7.5
        ctx.insert(exercise)
        try ctx.save()
    }

    do {
        let server = FakeSyncServer(), clock = SyncTestClock()
        let mine = try SyncCrypto.keys(for: SyncCrypto.newAccountKey())
        let mac = try SyncTestDevice(server: server, clock: clock, keys: mine)
        let pc = try SyncTestDevice(server: server, clock: clock, keys: mine)
        try store(mac.context)
        let r1 = mac.sync()
        note(r1.pushed == 3, "sync chiffrée : un premier passage envoie les 3 lignes (obtenu \(r1.pushed))")
        let env = server.data["sync_courses"]?.values.first
        note(Set(env?.keys.map { $0 } ?? []) == ["id", "updated_at", "deleted_at", "server_updated_at", "key_id", "payload"], "sync chiffrée : le serveur ne garde que l'enveloppe (id, dates, key_id, payload)")
        note(env?["key_id"] as? String == mine.keyID && (env?["payload"] as? String)?.hasPrefix("\\x") == true, "sync chiffrée : key_id et payload « \\x… »")
        let everything = String(describing: server.data)
        note(!everything.contains("Analyse") && !everything.contains("MATH-101") && !everything.contains("Limites"), "sync chiffrée : aucun contenu en clair côté serveur")
        let before = server.pushes
        note(mac.sync().pushed == 0 && server.pushes == before, "sync chiffrée : un second passage n'envoie rien (pas d'écho)")

        let r2 = pc.sync()
        let courses = try pc.context.fetch(FetchDescriptor<Course>())
        note(r2.pulled >= 3 && courses.count == 1 && courses[0].code == "MATH-101" && courses[0].credits == 8 && courses[0].weeklySelfStudyHours == 4.5, "sync chiffrée : l'autre appareil reçoit le cours et ses champs")
        note(courses.first?.series.first?.exercises.first?.score == 7.5, "sync chiffrée : … et les relations (séries, exercices)")
        let after = server.pushes
        note(pc.sync().pushed == 0 && server.pushes == after, "sync chiffrée : ce qui vient d'être lu n'est pas renvoyé")

        // La plus récente gagne.
        let ctxM = mac.context
        let cM = try ctxM.fetch(FetchDescriptor<Course>())[0]
        cM.name = "Analyse I (v2)"
        try ctxM.save()
        mac.sync()
        pc.sync()
        note(try pc.context.fetch(FetchDescriptor<Course>())[0].name == "Analyse I (v2)", "sync chiffrée : la modification la plus récente gagne")

        // Pierre tombale : sans payload, propagée, en cascade.
        let ctx = mac.context
        for c in try ctx.fetch(FetchDescriptor<Course>()) { ctx.delete(c) }
        try ctx.save()
        mac.sync()
        let tomb = server.data["sync_courses"]?.values.first
        note(tomb?["deleted_at"] is String && tomb?["payload"] is NSNull, "sync chiffrée : une suppression part sans payload")
        pc.sync()
        note(try (pc.context.fetch(FetchDescriptor<Course>()).isEmpty && pc.context.fetch(FetchDescriptor<Exercise>()).isEmpty), "sync chiffrée : … et se propage, avec la cascade")
    }

    do {
        // Une autre clé : les lignes sont sautées et comptées, jamais appliquées.
        let server = FakeSyncServer(), clock = SyncTestClock()
        let theirs = try SyncCrypto.keys(for: SyncCrypto.newAccountKey()), mine = try SyncCrypto.keys(for: SyncCrypto.newAccountKey())
        let other = try SyncTestDevice(server: server, clock: clock, keys: theirs)
        try store(other.context)
        other.sync()
        let stats = SyncSkipStats()
        let me = try SyncTestDevice(server: server, clock: clock, keys: mine, stats: stats)
        let report = me.sync()
        note(stats.foreignKey == 3 && report.pulled == 0, "sync chiffrée : trois lignes d'une autre clé sont comptées et sautées (obtenu \(stats.foreignKey))")
        note(try me.context.fetch(FetchDescriptor<Course>()).isEmpty, "sync chiffrée : … rien n'est appliqué")
        // Envoyer une ligne en face d'une ligne d'une autre clé : le serveur la renvoie, on le signale.
        let ctx = me.context
        let course = Course(code: "Z", name: "z")
        ctx.insert(course)
        try ctx.save()
        let id = course.id.uuidString.lowercased()
        server.data["sync_courses", default: [:]][id] = ["id": id, "updated_at": "2099-01-01T00:00:00+00:00", "deleted_at": NSNull(),
                                                         "server_updated_at": "2026-10-30T10:00:00.000001+00:00", "key_id": theirs.keyID, "payload": "\\x0102"]
        let failure = me.syncError(pull: false)
        note(failure is SyncForeignKeyError, "sync chiffrée : à l'envoi, une ligne d'une autre clé renvoyée par le serveur lève « clé différente »")
        note(server.data["sync_courses"]?[id]?["payload"] as? String == "\\x0102", "sync chiffrée : … et n'est pas écrasée")
    }

    do {
        // Une ligne déplacée sur un autre id (AAD) est illisible : sautée, comptée.
        let server = FakeSyncServer(), clock = SyncTestClock()
        let mine = try SyncCrypto.keys(for: SyncCrypto.newAccountKey())
        let a = try SyncTestDevice(server: server, clock: clock, keys: mine)
        let ctx = a.context
        let c1 = Course(code: "A", name: "a"), c2 = Course(code: "B", name: "b")
        ctx.insert(c1); ctx.insert(c2)
        try ctx.save()
        a.sync()
        let id1 = c1.id.uuidString.lowercased(), id2 = c2.id.uuidString.lowercased()
        let payload1 = server.data["sync_courses"]![id1]!["payload"]
        server.data["sync_courses"]![id2]!["payload"] = payload1 // le contenu de A sous l'identité de B
        let stats = SyncSkipStats()
        let b = try SyncTestDevice(server: server, clock: clock, keys: mine, stats: stats)
        b.sync()
        let got = try b.context.fetch(FetchDescriptor<Course>())
        note(stats.unreadableCount == 1 && got.count == 1 && got[0].code == "A", "sync chiffrée : une ligne recollée sous un autre id est illisible, sautée et comptée")
    }

    // MARK: Appairage

    func joinBlocking(_ code: String, keyID: String, relay: MemoryPairRelay, redirect: String? = nil, timeout: Duration = .seconds(5)) -> Result<Data, Error> {
        syncBlocking { () -> Result<Data, Error> in
            do { return .success(try await SyncPairingJoiner.join(code: code, expectedKeyID: keyID, timeout: timeout, makeSocket: relay.factory(redirect: redirect))) }
            catch { return .failure(error) }
        } ?? .failure(SyncPairingError.relay)
    }

    func failure(_ r: Result<Data, Error>) -> SyncPairingError? {
        if case .failure(let e) = r { return e as? SyncPairingError }
        return nil
    }

    do {
        let relay = MemoryPairRelay(), log = PairStateLog()
        let ak = SyncCrypto.newAccountKey()
        let keyID = try SyncCrypto.keys(for: ak).keyID
        let host = try SyncPairingHost(accountKey: ak, makeSocket: relay.factory(), onState: { log.add($0) })
        syncBlocking { await host.start() }
        let joined = joinBlocking(host.code, keyID: keyID, relay: relay)
        var got: Data?
        if case .success(let d) = joined { got = d }
        note(got == ak, "appairage : B reçoit exactement la clé de A")
        let state = syncBlocking { () -> SyncPairingHost.State in
            for _ in 0..<50 { if await host.state == .done { break }; try? await Task.sleep(for: .milliseconds(20)) }
            return await host.state
        }
        note(state == .done && log.states == [.verifying, .done], "appairage : A dit « terminé » (\(log.states))")
        note(relay.openSockets == 0, "appairage : les deux sockets sont fermées une fois fini")
        let seen = relay.log.joined() + relay.channels.joined()
        note(!seen.contains(hex(ak)) && !seen.contains(host.code) && !seen.contains(ak.base64EncodedString()), "appairage : le relais n'a vu ni la clé ni le code")
        note(relay.channels.allSatisfy { $0.hasPrefix("pair-") && $0.count == 37 }, "appairage : canal « pair-<32 hex> »")
    }

    do {
        // Code mal formé, mauvais code (personne ne répond), mauvais compte.
        let relay = MemoryPairRelay()
        let ak = SyncCrypto.newAccountKey()
        let keyID = try SyncCrypto.keys(for: ak).keyID
        let host = try SyncPairingHost(accountKey: ak, makeSocket: relay.factory())
        syncBlocking { await host.start() }
        note(failure(joinBlocking("1234", keyID: keyID, relay: relay)) == .invalidCode && relay.channels.count == 1, "appairage : un code mal formé est refusé sans toucher au réseau")
        let wrong = SyncCrypto.encodePairingCode(SyncCrypto.newPairingSecret())
        note(failure(joinBlocking(wrong, keyID: keyID, relay: relay, timeout: .milliseconds(150))) == .timeout, "appairage : un mauvais code n'obtient aucune réponse (délai écoulé, message calme)")
        note(failure(joinBlocking(host.code, keyID: String(repeating: "0", count: 32), relay: relay)) == .otherAccount, "appairage : la clé reçue doit être celle du coffre du compte connecté")
        syncBlocking { await host.cancel() }
    }

    do {
        // Même salon, mauvais secret : le déchiffrement échoue ; une seule tentative par code.
        let relay = MemoryPairRelay()
        let ak = SyncCrypto.newAccountKey()
        let keyID = try SyncCrypto.keys(for: ak).keyID
        let host = try SyncPairingHost(accountKey: ak, makeSocket: relay.factory())
        syncBlocking { await host.start() }
        let hostChannel = relay.channels[0]
        let wrong = SyncCrypto.encodePairingCode(SyncCrypto.newPairingSecret())
        note(failure(joinBlocking(wrong, keyID: keyID, relay: relay, redirect: hostChannel)) == .wrongCode, "appairage : bon salon, mauvais secret — le déchiffrement échoue, erreur claire")
        let state = syncBlocking { await host.state }
        note(state == .verifying, "appairage : A a répondu une fois et attend (\(String(describing: state)))")
        note(failure(joinBlocking(host.code, keyID: keyID, relay: relay, timeout: .milliseconds(200))) == .timeout, "appairage : une tentative par code — le bon code arrive trop tard")
        syncBlocking { await host.cancel() }
    }

    do {
        // Expiration et annulation ferment la socket.
        let relay = MemoryPairRelay(), log = PairStateLog()
        let host = try SyncPairingHost(accountKey: SyncCrypto.newAccountKey(), ttl: .milliseconds(80), makeSocket: relay.factory(), onState: { log.add($0) })
        syncBlocking { await host.start() }
        let opened = relay.openSockets
        let state = syncBlocking { () -> SyncPairingHost.State in
            for _ in 0..<50 { if await host.state == .expired { break }; try? await Task.sleep(for: .milliseconds(20)) }
            return await host.state
        }
        note(opened == 1 && state == .expired && relay.openSockets == 0 && log.states == [.expired], "appairage : le code expire, la socket se ferme")
        let second = try SyncPairingHost(accountKey: SyncCrypto.newAccountKey(), makeSocket: relay.factory())
        syncBlocking { await second.start() }
        syncBlocking { await second.cancel() }
        note(syncBlocking { await second.state } == .cancelled && relay.openSockets == 0, "appairage : annuler ferme la socket")
        note(SyncPairingHost.timeToLive == .seconds(600), "appairage : un code vaut dix minutes")
    }

    // MARK: Hôtes et vecteurs réseau

    do {
        let key = try SyncCrypto.keys(for: SyncCrypto.newAccountKey())
        note(key.keyID.count == 32 && key.keyID.allSatisfy { $0.isHexDigit }, "sync chiffrée : keyId = 32 caractères hexadécimaux (colonne key_id)")
    }
}
