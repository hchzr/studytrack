# Synchronisation chiffrée de bout en bout

La synchronisation Supabase (iPhone, Mac, Windows) est chiffrée **sur les appareils**. Le serveur
garde des octets qu'il ne sait pas lire.

## Menace

Protège contre :

- une fuite de la base Supabase (sauvegarde, export, accès en lecture) ;
- un serveur ou un relais curieux : il lit la base et le trafic, mais n'a jamais la clé.

Ne protège pas contre :

- **les métadonnées** : le serveur voit *quand* une ligne change (`updated_at`, `server_updated_at`),
  *combien* il y en a par table, quelles lignes sont supprimées (`deleted_at`), la taille des
  contenus, et l'identifiant public de la clé (`key_id`). Il ne voit ni les champs ni les relations ;
- **un serveur malveillant actif** : il peut servir d'anciennes versions de lignes, en retenir ou en
  supprimer — mais pas en fabriquer ni en modifier une (AES-GCM authentifie, et l'AAD lie chaque
  contenu à sa table et à son id : une ligne recollée ailleurs est refusée) ;
- **un appareil compromis** : la clé est en clair en mémoire et lisible par l'app sur l'appareil ;
- **la perte de toutes les clés** : sans appareil connecté ni clé de secours, les données du serveur
  sont perdues (il reste « Réinitialiser le coffre »).

Le relais ne voit que deux clés publiques éphémères et des chiffrés pendant un appairage ; il ne
garde jamais un message `pair`.

## Clés

| Nom | Valeur |
|---|---|
| `AK` | 32 octets aléatoires, créés par le premier appareil qui active la synchronisation d'un compte sans coffre |
| `dataKey` | HKDF-SHA256(ikm = AK, sel vide, info `studytrack/sync/data/v1`, 32 octets) |
| `keyId` | HKDF-SHA256(ikm = AK, sel vide, info `studytrack/sync/key-id/v1`, 16 octets), en hexadécimal |

`AK` n'existe que sur les appareils : trousseau Apple (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
non synchronisable) ; coffre du système sous Windows (Credential Manager, via `src/native/secrets.ts`).
Elle n'est jamais envoyée à Supabase, sous aucune forme. Une clé par compte (id utilisateur).

## Tables

`supabase/migrations/20261103000000_sync_e2ee.sql` (générée par `windows/scripts/gen-schema.ts`).
L'ancienne migration `20261030000000_user_data_sync.sql` reste telle qu'appliquée ; la nouvelle
supprime ses 15 tables (vides) et les recrée :

```
id uuid pk · user_id (défaut auth.uid(), cascade) · updated_at · deleted_at
server_updated_at (posé par le serveur) · payload bytea (nul pour une pierre tombale) · key_id text
```

Les champs du modèle (`windows/src/models/schema.ts`, toujours la source) vivent dans `payload`.
La garde garde ses règles (propriétaire immuable, écriture plus ancienne ignorée, curseur posé par
le serveur) et refuse de changer le `key_id` d'une ligne : un appareil ne peut pas écraser du contenu
d'une autre clé. RLS : propriétaire seulement.

`sync_vault(user_id pk, key_id, created_at)` : un coffre par compte, écrit une fois (aucune politique
d'`UPDATE`, déclencheur qui refuse aussi toute mise à jour). Il dit à un nouvel appareil qu'une clé
existe et laquelle, pour vérifier la clé reçue. Aucun secret.
`sync_reset_vault()` supprime, en une transaction, les lignes et le coffre du compte appelant.

## Ligne chiffrée

- Plaintext : JSON UTF-8 des champs, mêmes clés que les anciennes colonnes, mêmes encodages de valeurs,
  relations en `<nom>_id`. Clés triées, compact (`id`, `updated_at`, `deleted_at` restent en clair).
- `payload = nonce(12, aléatoire) ‖ AES-256-GCM(dataKey, plaintext, AAD) ‖ tag(16)`,
  AAD = `"<table>/<id en minuscules>/v1"`.
- Sur PostgREST, `bytea` s'écrit `\x` + hexadécimal, à l'envoi comme à la réception.
- Une ligne dont `key_id` ≠ celui de l'appareil est **sautée** (« clé différente »), comptée, jamais
  appliquée ni écrasée. Une ligne de la bonne clé qui ne s'ouvre pas (altérée, déplacée) est sautée et
  comptée « illisible ». Une pierre tombale n'a pas de payload.
- Avant chaque passe l'appareil relit son coffre (une requête) : un coffre réinitialisé ailleurs se
  voit tout de suite, et l'appareil n'envoie plus rien tant qu'il n'a pas la nouvelle clé.

## Appairage d'un appareil

Pour un compte qui a déjà un coffre. L'appareil B doit être connecté au même compte.

1. A : « Ajouter un appareil » → `S` (16 octets aléatoires), montré en code Crockford base32
   (26 caractères, `XXXX-XXXX-…-XX`) et en QR `studytrack-pair:<code>`. Valable 10 minutes.
2. B saisit (ou scanne) le code. Canal du relais : `pair-` + hex(HKDF(S, info `studytrack/pair/channel/v1`, 16)).
3. A et B ouvrent une WebSocket `wss://<relais>/v1/<canal>?device=<uuid>`.
4. B → `hello {pubB}` (X25519 éphémère). A → `offer {pubA, box}`.
   `k = HKDF(ikm = ECDH(eA,eB) ‖ S, info = "studytrack/pair/key/v1" ‖ pubA ‖ pubB, 32)` ;
   `box = AES-GCM(k, AK, AAD "studytrack/pair/ak/v1")`.
5. B ouvre `box`, vérifie `keyId(AK)` = `sync_vault.key_id` de son compte, range `AK`, répond
   `ok {AES-GCM(k, "ok", AAD "studytrack/pair/ok/v1")}`. Les deux écrans disent « Appareil ajouté ».

`S` ne transite jamais ; le relais ne voit que `pubA`, `pubB` et des chiffrés. Un mauvais code donne
un autre canal (personne ne répond : délai, message calme) ou, sur le bon canal, un déchiffrement qui
échoue. Une tentative par code : A ignore tout `hello` après le premier. Les sockets ne sont ouvertes
que pendant l'écran d'appairage (coût au repos nul).

Relais : message `pair` transmis aux autres sockets du salon `pair-…`, jamais gardé (ni `last`, ni
stockage), 4 Ko au plus, 4 sockets au plus par salon.

## Clé de secours

`AK` en Crockford base32 (52 caractères) + 2 caractères de contrôle (10 premiers bits de
SHA-256(`studytrack/recovery/v1` ‖ AK)), par groupes de 4. Montrée une fois à la création du coffre,
puis sur demande après confirmation. « Utiliser la clé de secours » sur un nouvel appareil : la clé
est vérifiée contre le `key_id` du coffre avant d'être rangée.

## Réinitialiser le coffre

Dernier recours (tous les appareils et la clé de secours perdus). Confirmation forte (taper
`RÉINITIALISER`). `sync_reset_vault()` efface lignes et coffre du compte ; l'appareil crée un coffre
neuf, affiche la nouvelle clé de secours, et renvoie ses données locales. Les autres appareils voient
« clé différente » et n'envoient plus rien.

## Compatibilité entre plateformes

`supabase/e2ee-vectors.json` est lu par `windows/tests/domain/syncCrypto.test.ts` (WebCrypto) et par
`Validation/SyncCryptoTests.swift` (CryptoKit) : clé figée → `keyId` et `dataKey` ; ligne figée +
nonce figé → payload exact ; secret et clés éphémères figés → canal, `k`, `AK` scellée, confirmation ;
clé de secours et code. Seul le chiffrement doit coïncider octet pour octet ; le JSON se relit partout
(les deux côtés l'écrivent à clés triées, mêmes échappements).

## Où est le code

| | Windows | Apple |
|---|---|---|
| Primitives | `windows/src/domain/syncCrypto.ts` | `StudyTrack/Domain/SyncCrypto.swift` |
| Lignes chiffrées | `windows/src/sync/encryptedTransport.ts` | `StudyTrack/Domain/SyncEncryption.swift` |
| Appairage | `windows/src/services/syncPairing.ts` | `StudyTrack/Domain/SyncPairing.swift`, `Services/SyncDeviceLink.swift` |
| Service | `windows/src/services/syncService.ts` | `StudyTrack/Services/SupabaseSync.swift` |
| Écrans | `…/settings/SyncEncryption.tsx` | `Views/Stats/SyncEncryptionViews.swift` |
| Relais | `relay/src/index.ts` | |
