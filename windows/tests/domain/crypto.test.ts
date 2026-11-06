// Port des sections « Entraide chiffrée de bout en bout (GroupCrypto) » et « Diagnostic des
// erreurs Supabase » (GroupErrorExplainer) de Validation/main.swift, plus l'interopérabilité
// octet pour octet avec le GroupCrypto.swift de l'iPhone et du Mac (CryptoKit).
//
// Comment les fixtures ont été produites (une seule fois, à la main, rien dans le dépôt
// hors de ce dossier) :
//   1. Un script Swift (copie dans fixtures/crypto/interop.swift.txt) a été compilé avec
//      Polymestre/Domain/GroupCrypto.swift :
//        swiftc -O GroupCrypto.swift main.swift -o gc
//      `./gc gen > fixtures/crypto/swift-vectors.json` écrit un groupe, une clé de groupe,
//      des messages scellés (accents, vide, émoji, retour à la ligne), deux identités
//      Curve25519 (clés brutes en base64) et les enveloppes Alice→Bob et Bob→Alice.
//   2. Ce fichier de test déchiffre tout swift-vectors.json avec le code TypeScript
//      (sens Swift → TS).
//   3. Un script Node (`node gen-ts.ts`, qui importe src/domain/groupCrypto.ts) a produit
//      fixtures/crypto/ts-vectors.json dans le même format, avec des clés neuves ;
//      `./gc verify ts-vectors.json` l'a relu avec GroupCrypto.swift : messages, clés
//      publiques dérivées et enveloppes, tous « OK » (sens TS → Swift).
//   4. Pour rejouer le sens TS → Swift : régénérer ts-vectors.json avec le script de l'étape 3
//      puis relancer `./gc verify`. Ici, le test relit ts-vectors.json avec le code TS (garde
//      contre une dérive du format) ; les deux fichiers sont des instantanés.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import * as G from "../../src/domain/groupCrypto.ts";
import { GroupErrorExplainer } from "../../src/domain/groupErrorExplainer.ts";

const group = "56B0C700-8B2E-4D63-A661-7CDB3E9B026F";
const rejects = async (p: Promise<unknown>): Promise<boolean> => p.then(() => false, () => true);
const b64 = (s: string): Uint8Array => G.base64Decode(s)!;

describe("Entraide chiffrée de bout en bout (GroupCrypto)", async () => {
  const alice = await G.newIdentity();
  const bob = await G.newIdentity();
  const eve = await G.newIdentity();
  const key = G.newGroupKey();
  const text = "Je bloque sur 4.3 (b) — l'intégrale ∫ diverge ?";
  const sealed = await G.seal(text, key, group, "a1");

  it("le message part chiffré, versionné, sans texte lisible", () => {
    expect(sealed.startsWith("v1:") && !sealed.includes("bloque")).toBe(true);
  });
  it("déchiffré à l'identique, accents et symboles compris (identifiants insensibles à la casse)", async () => {
    expect(await G.open(sealed, key, group.toLowerCase(), "A1").catch(() => null)).toBe(text);
  });
  it("recollé sous le nom d'un autre auteur : refusé", async () => {
    expect(await rejects(G.open(sealed, key, group, "b2"))).toBe(true);
  });
  it("recollé dans un autre groupe : refusé", async () => {
    expect(await rejects(G.open(sealed, key, "autre-groupe", "a1"))).toBe(true);
  });
  it("une autre clé ne l'ouvre pas", async () => {
    expect(await rejects(G.open(sealed, G.newGroupKey(), group, "a1"))).toBe(true);
  });
  it("l'identifiant de clé est stable et court", async () => {
    const id = await G.keyID(key);
    expect(id === await G.keyID(G.decodeKey(G.encode(key))!) && id.length === 16).toBe(true);
  });

  const envelope = await G.wrap(key, alice.privateKey, bob.publicKey, group);
  it("Bob ouvre l'enveloppe qu'Alice lui a scellée", async () => {
    const opened = await G.unwrap(envelope, bob.privateKey, alice.publicKey, group).catch(() => null);
    expect(opened !== null && (await G.keyID(opened)) === (await G.keyID(key))).toBe(true);
  });
  it("Ève, qui lit la base, ne l'ouvre pas", async () => {
    expect(await rejects(G.unwrap(envelope, eve.privateKey, alice.publicKey, group))).toBe(true);
  });
  it("une enveloppe ne sert que pour son groupe", async () => {
    expect(await rejects(G.unwrap(envelope, bob.privateKey, alice.publicKey, "autre"))).toBe(true);
  });
  it("clé publique publiée en base64 (44 caractères, accepté par la contrainte SQL)", () => {
    const pk = G.publicKeyString(bob.publicKey);
    expect(pk.length === 44 && G.publicKey(pk) !== null
      && G.base64Encode(G.publicKey(pk)!) === G.base64Encode(bob.publicKey)).toBe(true);
  });
  it("distribution : seules les clés de membres non servies, sans doublon ni ancien membre", () => {
    const missing = G.missingRecipients(new Set(["a", "b", "c"]),
      [{ userID: "a", key: "KA" }, { userID: "b", key: "KB" }, { userID: "b", key: "KB2" },
        { userID: "x", key: "KX" }, { userID: "b", key: "KB" }],
      new Set(["KA"]));
    expect(missing.map((m) => m.key)).toEqual(["KB", "KB2"]);
  });

  // Garde-fous maison (formats refusés comme CryptoKit les refuse).
  it("un message sans préfixe ou mal encodé est « malformed »", async () => {
    for (const bad of ["pas chiffré", "v1:@@@", "v1:" + G.base64Encode(new Uint8Array(10))]) {
      await expect(G.open(bad, key, group, "a1")).rejects.toMatchObject({ kind: "malformed" });
    }
    await expect(G.open(sealed, G.newGroupKey(), group, "a1")).rejects.toMatchObject({ kind: "wrongKey" });
  });
  it("decodeKey refuse une clé qui ne fait pas 32 octets", () => {
    expect(G.decodeKey(G.base64Encode(new Uint8Array(16)))).toBeNull();
    expect(G.decodeKey("pas du base64")).toBeNull();
  });
});

describe("Interopérabilité avec CryptoKit (GroupCrypto.swift)", () => {
  type Vectors = {
    groupID: string; authorID: string; groupKey: string; keyID: string;
    messages: { plaintext: string; sealed: string }[];
    alice: { priv: string; pub: string }; bob: { priv: string; pub: string };
    envelopeAliceToBob: string; envelopeBobToAlice: string;
  };
  const load = (name: string): Vectors =>
    JSON.parse(readFileSync(new URL(`../fixtures/crypto/${name}`, import.meta.url), "utf8"));

  for (const [file, origine] of [["swift-vectors.json", "Swift"], ["ts-vectors.json", "TypeScript"]] as const) {
    const v = load(file);
    const groupKey = G.decodeKey(v.groupKey)!;

    it(`${origine} : l'identifiant de clé est le même`, async () => {
      expect(await G.keyID(groupKey)).toBe(v.keyID);
    });
    v.messages.forEach((m, i) => {
      it(`${origine} : message ${i + 1} (« ${m.plaintext.slice(0, 12).replace("\n", " ")} ») déchiffré`, async () => {
        expect(await G.open(m.sealed, groupKey, v.groupID, v.authorID)).toBe(m.plaintext);
      });
    });
    it(`${origine} : la clé publique se dérive de la clé privée`, async () => {
      expect(G.base64Encode(await G.x25519(b64(v.alice.priv), (() => { const b = new Uint8Array(32); b[0] = 9; return b; })())))
        .toBe(v.alice.pub);
      expect(G.base64Encode(await G.x25519(b64(v.bob.priv), (() => { const b = new Uint8Array(32); b[0] = 9; return b; })())))
        .toBe(v.bob.pub);
    });
    it(`${origine} : Bob ouvre l'enveloppe d'Alice`, async () => {
      const opened = await G.unwrap(v.envelopeAliceToBob, b64(v.bob.priv), b64(v.alice.pub), v.groupID);
      expect(G.encode(opened)).toBe(v.groupKey);
    });
    it(`${origine} : Alice ouvre l'enveloppe de Bob`, async () => {
      const opened = await G.unwrap(v.envelopeBobToAlice, b64(v.alice.priv), b64(v.bob.pub), v.groupID);
      expect(G.encode(opened)).toBe(v.groupKey);
    });
  }

  it("RFC 7748 §5.2 : vecteur d'essai de la multiplication X25519", async () => {
    const hex = (h: string) => Uint8Array.from(h.match(/../g)!.map((x) => parseInt(x, 16)));
    const out = await G.x25519(
      hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
      hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"));
    expect(Array.from(out, (b) => b.toString(16).padStart(2, "0")).join(""))
      .toBe("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
  });
});

describe("Diagnostic des erreurs Supabase", () => {
  // Ce traducteur a menti deux fois : « politiques RLS » sans dire quelle table, et
  // un message qui laissait croire qu'un simple réexécutable suffisait. On le teste
  // donc sur les réponses **réelles** de PostgREST.
  const rlsBody = '{"code":"42501","message":"new row violates row-level security policy for table \\"presence\\"","details":null,"hint":null}';
  const rls = GroupErrorExplainer.explain(`Erreur serveur (403) : ${rlsBody}`);

  it("un 42501 oriente vers l'adhésion manquante", () => { expect(rls).toContain("membre du groupe"); });
  it("…et nomme la table refusée", () => { expect(rls).toContain("presence"); });
  it("…et conserve le code serveur", () => { expect(rls).toContain("42501"); });
  it("un « permission denied » est distingué d'une politique RLS", () => {
    const denied = GroupErrorExplainer.explain('Erreur serveur (403) : {"code":"42501","message":"permission denied for table presence"}');
    expect(denied).toContain("droits manquants");
  });
  it("une table absente renvoie au fichier SQL", () => {
    expect(GroupErrorExplainer.explain(`Erreur serveur (404) : {"code":"PGRST205","message":"Could not find the table 'public.presence' in the schema cache"}`))
      .toContain("supabase-schema.sql");
  });
  it("une imbrication ambiguë est expliquée", () => {
    expect(GroupErrorExplainer.explain('Erreur serveur (300) : {"code":"PGRST201","message":"Could not embed because more than one relationship was found"}'))
      .toContain("deux chemins");
  });
  it("une violation de clé étrangère renvoie au profil", () => {
    expect(GroupErrorExplainer.explain('Erreur serveur (409) : {"code":"23503","message":"insert or update on table violates foreign key constraint"}'))
      .toContain("profil");
  });
  it("une erreur non reconnue est rendue telle quelle, sans invention", () => {
    const raw = "Erreur serveur (500) : panne inconnue";
    expect(GroupErrorExplainer.explain(raw)).toBe(raw);
  });
  it("sans JSON, aucun détail inventé", () => {
    expect(GroupErrorExplainer.serverDetail("pas de json ici")).toBe("");
  });
  it("un code seul est tout de même repris", () => {
    expect(GroupErrorExplainer.serverDetail('{"code":"X"}')).toContain("code X");
  });
  it("un message vide ne produit pas de « Serveur : » orphelin", () => {
    expect(GroupErrorExplainer.serverDetail('{"message":""}')).toBe("");
  });
  it("l'indication du serveur est conservée", () => {
    expect(GroupErrorExplainer.serverDetail('{"message":"boom","hint":"essaie ceci"}')).toContain("essaie ceci");
  });
});
