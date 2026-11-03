// Le chiffrement de bout en bout de la synchronisation : les vecteurs communs avec Swift
// (supabase/e2ee-vectors.json, relus par Validation/SyncCryptoTests.swift), puis les propriétés.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import * as C from "../../src/domain/syncCrypto.ts";
import { EncryptedTransport, SkipStats, ForeignKeyError } from "../../src/sync/encryptedTransport.ts";
import type { Row } from "../../src/sync/store.ts";
import type { Transport } from "../../src/sync/engine.ts";

const V = JSON.parse(readFileSync(new URL("../../../supabase/e2ee-vectors.json", import.meta.url), "utf8"));
const bytes = (hex: string): Uint8Array => C.fromHex(hex)!;
const rejects = (p: Promise<unknown>) => p.then(() => false, () => true);

describe("vecteurs communs avec Swift", () => {
  it("clé du compte → keyId et dataKey", async () => {
    const { dataKey, keyId } = await C.deriveKeys(bytes(V.accountKey));
    expect(C.toHex(dataKey)).toBe(V.dataKey);
    expect(keyId).toBe(V.keyId);
  });

  it("ligne figée + nonce figé → payload exact", async () => {
    const { row } = V;
    expect(C.canonicalJSON(row.fields)).toBe(row.plaintext);
    expect(new TextDecoder().decode(C.rowAAD(row.table, row.id))).toBe(row.aad);
    const box = await C.sealRow(bytes(V.dataKey), row.table, row.id, row.fields, bytes(row.nonce));
    expect(C.toHex(box)).toBe(row.payload);
    expect(C.toBytea(box)).toBe(row.bytea);
    expect(await C.openRow(bytes(V.dataKey), row.table, row.id, bytes(row.payload))).toEqual(row.fields);
  });

  it("clé de secours et code d'appairage", async () => {
    expect(await C.encodeRecoveryKey(bytes(V.accountKey))).toBe(V.recoveryKey);
    expect(C.toHex(await C.decodeRecoveryKey(V.recoveryKey))).toBe(V.accountKey);
    const p = V.pairing;
    expect(C.encodePairingCode(bytes(p.secret))).toBe(p.code);
    expect(C.pairingQRText(bytes(p.secret))).toBe(p.qr);
    expect(C.toHex(C.parsePairingInput(p.qr)!)).toBe(p.secret);
  });

  it("appairage : canal, clé k, AK scellée et confirmation", async () => {
    const p = V.pairing;
    const s = bytes(p.secret);
    expect(await C.pairChannel(s)).toBe(p.channel);
    const eA = await C.newEphemeral(bytes(p.privateA));
    const eB = await C.newEphemeral(bytes(p.privateB));
    expect(C.toHex(eA.publicKey)).toBe(p.publicA);
    expect(C.toHex(eB.publicKey)).toBe(p.publicB);
    const kA = await C.pairKey(eA.privateKey, eB.publicKey, s, eA.publicKey, eB.publicKey);
    const kB = await C.pairKey(eB.privateKey, eA.publicKey, s, eA.publicKey, eB.publicKey);
    expect(C.toHex(kA)).toBe(p.key);
    expect(C.toHex(kB)).toBe(p.key);
    expect(C.toHex(await C.sealAccountKey(kA, bytes(V.accountKey), bytes(p.nonceAK)))).toBe(p.sealedAccountKey);
    expect(C.toHex(await C.openAccountKey(kB, bytes(p.sealedAccountKey)))).toBe(V.accountKey);
    expect(C.toHex(await C.sealOk(kA, bytes(p.nonceOk)))).toBe(p.sealedOk);
    expect(await C.openOk(kA, bytes(p.sealedOk))).toBe(true);
  });
});

describe("lignes chiffrées", () => {
  const fields = { name: "Analyse I", credits: 7.5, is_active: true, notes: null };

  it("aller-retour ; deux scellements du même contenu diffèrent (nonce aléatoire)", async () => {
    const { dataKey } = await C.deriveKeys(C.newAccountKey());
    const a = await C.sealRow(dataKey, "sync_courses", "c1", fields);
    const b = await C.sealRow(dataKey, "sync_courses", "c1", fields);
    expect(C.toHex(a)).not.toBe(C.toHex(b));
    expect(await C.openRow(dataKey, "sync_courses", "c1", a)).toEqual(fields);
    expect(a.length).toBe(12 + C.canonicalJSON(fields).length + 16);
  });

  it("une ligne déplacée vers un autre id ou une autre table ne s'ouvre pas ; la casse de l'id ne compte pas", async () => {
    const { dataKey } = await C.deriveKeys(C.newAccountKey());
    const box = await C.sealRow(dataKey, "sync_courses", "AbC-1", fields);
    expect(await rejects(C.openRow(dataKey, "sync_courses", "other", box))).toBe(true);
    expect(await rejects(C.openRow(dataKey, "sync_exams", "AbC-1", box))).toBe(true);
    expect(await C.openRow(dataKey, "sync_courses", "abc-1", box)).toEqual(fields);
  });

  it("mauvaise clé, octet modifié, boîte trop courte : refus", async () => {
    const { dataKey } = await C.deriveKeys(C.newAccountKey());
    const other = (await C.deriveKeys(C.newAccountKey())).dataKey;
    const box = await C.sealRow(dataKey, "t", "i", fields);
    expect(await rejects(C.openRow(other, "t", "i", box))).toBe(true);
    const tampered = box.slice(); tampered[20] ^= 1;
    expect(await rejects(C.openRow(dataKey, "t", "i", tampered))).toBe(true);
    expect(await rejects(C.openRow(dataKey, "t", "i", box.slice(0, 20)))).toBe(true);
  });

  it("bytea : « \\x » puis l'hexadécimal, strict", () => {
    expect(C.toBytea(Uint8Array.from([1, 255]))).toBe("\\x01ff");
    expect(C.fromBytea("\\x01ff")).toEqual(Uint8Array.from([1, 255]));
    expect(C.fromBytea("01ff")).toBeNull();
    expect(C.fromBytea("\\x0")).toBeNull();
    expect(C.fromBytea(null)).toBeNull();
  });
});

describe("clé de secours et code", () => {
  it("aller-retour, tolérant (minuscules, espaces, O/I/L), 54 caractères par groupes de 4", async () => {
    const ak = C.newAccountKey();
    const text = await C.encodeRecoveryKey(ak);
    expect(text.replace(/-/g, "")).toHaveLength(54);
    expect(text.split("-").every((g, i, all) => g.length === (i === all.length - 1 ? 2 : 4))).toBe(true);
    expect(await C.decodeRecoveryKey(text)).toEqual(ak);
    expect(await C.decodeRecoveryKey(text.toLowerCase().replace(/-/g, " "))).toEqual(ak);
    expect(await C.decodeRecoveryKey(text.replace(/0/g, "O").replace(/1/g, "l"))).toEqual(ak);
  });

  it("une faute de frappe est détectée (somme de contrôle), une clé trop courte aussi", async () => {
    const text = await C.encodeRecoveryKey(C.newAccountKey());
    const chars = [...text];
    const i = chars.findIndex((c, k) => c !== "-" && k > 3);
    chars[i] = chars[i] === "7" ? "8" : "7";
    await expect(C.decodeRecoveryKey(chars.join(""))).rejects.toMatchObject({ kind: "checksum" });
    await expect(C.decodeRecoveryKey(text.slice(0, 30))).rejects.toMatchObject({ kind: "format" });
    await expect(C.decodeRecoveryKey("U".repeat(54))).rejects.toMatchObject({ kind: "format" }); // U n'existe pas
  });

  it("le code d'appairage : 26 caractères, bits de remplissage nuls exigés", () => {
    const s = C.newPairingSecret();
    const code = C.encodePairingCode(s);
    expect(code.replace(/-/g, "")).toHaveLength(26);
    expect(C.decodePairingCode(code)).toEqual(s);
    expect(C.decodePairingCode(code.slice(0, -1))).toBeNull();
    // Le dernier symbole ne porte que 3 bits utiles : un autre symbole que celui du remplissage nul est refusé.
    const flat = code.replace(/-/g, "");
    expect(C.decodePairingCode(flat.slice(0, 25) + (flat[25] === "Z" ? "Y" : "Z"))).toBeNull();
  });
});

describe("appairage (primitives)", () => {
  it("un autre secret S donne une autre clé, même avec les mêmes clés publiques", async () => {
    const eA = await C.newEphemeral(), eB = await C.newEphemeral();
    const k1 = await C.pairKey(eA.privateKey, eB.publicKey, C.newPairingSecret(), eA.publicKey, eB.publicKey);
    const k2 = await C.pairKey(eA.privateKey, eB.publicKey, C.newPairingSecret(), eA.publicKey, eB.publicKey);
    expect(C.toHex(k1)).not.toBe(C.toHex(k2));
    expect(await rejects(C.openAccountKey(k2, await C.sealAccountKey(k1, C.newAccountKey())))).toBe(true);
    // La boîte de la clé n'est pas la confirmation, et réciproquement.
    expect(await C.openOk(k1, await C.sealAccountKey(k1, C.newAccountKey()))).toBe(false);
  });
});

/** Un serveur d'enveloppes minimal, pour le décorateur. */
class EnvelopeServer implements Transport {
  rows = new Map<string, Row>();
  async push(_t: string, rows: Row[]): Promise<Row[]> {
    return rows.map((r) => { const kept = { ...r, server_updated_at: "2026-11-01T10:00:00.000+00:00" }; this.rows.set(String(r.id), kept); return kept; });
  }
  async pull() { return { rows: [...this.rows.values()] }; }
}

describe("EncryptedTransport", () => {
  it("scelle à l'envoi, ouvre à la lecture ; pierre tombale sans payload", async () => {
    const keys = await C.deriveKeys(C.newAccountKey());
    const server = new EnvelopeServer();
    const t = new EncryptedTransport(server, keys);
    await t.push("sync_courses", [
      { id: "c1", name: "Analyse I", credits: 8, updated_at: "2026-11-01T10:00:00.000Z", deleted_at: null },
      { id: "c2", name: "Supprimé", updated_at: "2026-11-01T11:00:00.000Z", deleted_at: "2026-11-01T11:00:00.000Z" },
    ]);
    expect(server.rows.get("c2")!.payload).toBeNull();
    expect(Object.keys(server.rows.get("c1")!)).not.toContain("name");
    const { rows } = await t.pull("sync_courses", null, null, 10);
    expect(rows.find((r) => r.id === "c1")).toMatchObject({ name: "Analyse I", credits: 8, deleted_at: null });
    expect(rows.find((r) => r.id === "c2")).toMatchObject({ _tombstone: true });
  });

  it("une ligne déplacée sur un autre id est illisible : sautée et comptée, pas appliquée", async () => {
    const keys = await C.deriveKeys(C.newAccountKey());
    const server = new EnvelopeServer();
    const t = new EncryptedTransport(server, keys);
    await t.push("sync_courses", [{ id: "c1", name: "A", updated_at: "2026-11-01T10:00:00.000Z", deleted_at: null }]);
    const moved = { ...server.rows.get("c1")!, id: "c9" };
    server.rows.set("c9", moved);
    const { rows } = await t.pull("sync_courses", null, null, 10);
    expect(rows.find((r) => r.id === "c9")).toMatchObject({ _skipped: "unreadable" });
    expect(rows.find((r) => r.id === "c9")!.name).toBeUndefined();
    expect(t.stats.unreadable).toBe(1);
  });

  it("une autre clé : sautée à la lecture (comptée), erreur à l'envoi", async () => {
    const mine = await C.deriveKeys(C.newAccountKey());
    const theirs = await C.deriveKeys(C.newAccountKey());
    const server = new EnvelopeServer();
    await new EncryptedTransport(server, theirs).push("sync_courses", [{ id: "c1", name: "A", updated_at: "2026-11-01T10:00:00.000Z", deleted_at: null }]);
    const stats = new SkipStats();
    const t = new EncryptedTransport(server, mine, stats);
    const { rows } = await t.pull("sync_courses", null, null, 10);
    expect(rows[0]).toMatchObject({ id: "c1", _skipped: "foreignKey" });
    expect(stats.foreignKey).toBe(1);
    // Le serveur (qui ne remplace pas une ligne d'une autre clé) renverrait la leur : on le signale.
    const stubborn: Transport = { push: async () => [...server.rows.values()], pull: async () => ({ rows: [] }) };
    await expect(new EncryptedTransport(stubborn, mine).push("sync_courses",
      [{ id: "c1", name: "B", updated_at: "2026-11-01T12:00:00.000Z", deleted_at: null }])).rejects.toBeInstanceOf(ForeignKeyError);
  });
});
