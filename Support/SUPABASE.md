# Supabase — mode opératoire complet

Tout ce qui suit est **facultatif**. Sans projet Supabase, StudyTrack fonctionne
entièrement hors ligne : cours, séries, exercices, théorie, chrono, statistiques,
agenda, annales, plan de révision, widgets et Live Activity.

Ce que Supabase apporte, et rien d'autre :

| Fonction | Sans Supabase | Avec Supabase |
|---|---|---|
| Groupes d'étude (membres, avancement, présence, planning) | indisponible | ✅ |
| Analyse IA des PDF sans Apple Intelligence | lecture par motifs | ✅ via la fonction `extract-series` |
| Compte et connexion | aucun | Sign in with Apple ou e-mail |

---

## 1. Créer le projet

1. Va sur <https://supabase.com/dashboard> et connecte-toi.
2. **New project**.
   - **Name** : `studytrack`.
   - **Database Password** : clique sur *Generate a password* et **conserve-le**
     quelque part. Il ne sert pas à l'app, mais tu en auras besoin pour tout accès
     direct à la base.
   - **Region** : `Europe (Frankfurt)` ou `Europe (Zurich)` — le plus proche de
     Lausanne, pour la latence.
   - **Pricing Plan** : `Free` suffit largement.
3. Attends ~2 minutes que le projet soit provisionné.

---

## 2. Relever les deux clés et les mettre dans le projet

Dans le tableau de bord : **Project Settings** (roue dentée, en bas à gauche) →
**API**.

Tu y trouves deux valeurs :

| Ce qu'il faut copier | Où c'est écrit |
|---|---|
| `Project URL` | en haut, de la forme `https://abcdefghijklmnop.supabase.co` |
| `anon` `public` | dans **Project API keys**, la longue chaîne qui commence par `eyJ…` |

Édite `Support/Supabase.xcconfig` à la racine du dépôt :

```
SUPABASE_HOST = abcdefghijklmnop.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9....
```

> **Attention au `https://`.** Un fichier `.xcconfig` considère `//` comme le début
> d'un commentaire : écrire `https://abcdef…` ne garderait que `https:`. Le fichier
> contient `SUPABASE_HOST` **sans** le schéma ; l'app ajoute `https://` elle-même.

> **La clé `anon` est publique par conception.** Elle ne donne accès qu'à ce que les
> politiques RLS autorisent. Ne mets **jamais** la clé `service_role` dans l'app :
> elle contourne toutes les politiques.

Ensuite, dans Xcode : **Product ▸ Clean Build Folder** (⇧⌘K), puis rebuild. Ces
valeurs sont *compilées* dans l'app — il n'y a aucun champ à remplir à l'écran.

---

## 3. Créer les tables, les politiques et les fonctions

1. Dans le tableau de bord : **SQL Editor** → **New query**.
2. Ouvre `Support/supabase-schema.sql`, **copie tout**, colle, puis **Run**.
3. Tu dois voir `Success. No rows returned`.

Ce fichier est **idempotent** : tu peux le relancer autant de fois que tu veux, il ne
casse rien et ne duplique rien. **Relance-le après chaque mise à jour de l'app** qui
touche aux données sociales.

Il crée :

**Tables** — `profiles`, `courses_catalog`, `study_groups`, `group_members`,
`planned_sessions`, `session_rsvps`, `study_log_public`, `series_completion`,
`item_completion`, `group_courses`, `member_courses`, `presence`, `xp_events`.

**Fonction de classement** — `group_leaderboard(group_id)`, appelée par l'app.

**Déclencheur** `handle_new_user` — crée la ligne `profiles` à l'inscription, et
**rattrape les comptes déjà existants**. Sans lui, la première création de groupe
échoue avec une violation de clé étrangère (`23503`).

**Sécurité (RLS)** — chaque table est lisible par les membres du groupe et écrite par
son seul auteur. `group_courses` (les matières du groupe) est réservé aux
administrateurs ; `member_courses` (celles que tu suis) t'appartient.

**Droits de table explicites** — `grant select, insert, update, delete … to
authenticated`. Un `42501 permission denied for table …` sur une **lecture** ne vient
jamais des politiques RLS (elles filtrent en silence) mais d'un droit manquant.

**Ménage de la présence** — `presence_sweep()`, appelée une fois, et la commande
`pg_cron` en commentaire pour l'automatiser.

---

## 4. Vérifier que tout est en place

Ouvre `Support/supabase-check.sql`, copie tout, colle dans le **SQL Editor**, **Run**.
C'est un script **en lecture seule** : il ne modifie rien.

Il répond à quatre questions :

1. **Suis-je membre de mes groupes ?**
   `mes_adhesions = 0` sur une ligne où `je_suis_createur = true` signale le défaut
   qui casse la présence et l'avancement : le groupe existe côté serveur, mais sans
   son créateur. L'app le répare au prochain « Réparer et réessayer ».
2. **Les tables attendues existent-elles ?** Les neuf doivent répondre `true`.
3. **Les politiques RLS sont-elles en place ?** Chaque table doit avoir `rls_activee
   = true` **et** au moins une politique. Une table avec RLS active et zéro politique
   refuse **tout**.
4. **Les droits sont-ils accordés ?** Il doit y avoir des lignes pour `authenticated`
   sur `item_completion`, `group_courses`, `member_courses` et `presence`.

---

## 5. Activer la connexion

**Authentication** ▸ **Providers**.

### E-mail / mot de passe

Déjà actif. Pour tester sans confirmer les adresses :
**Authentication** ▸ **Sign In / Providers** ▸ **Email** ▸ désactive
*Confirm email*. À réactiver avant toute mise en production.

### Sign in with Apple

Trois étapes, dans cet ordre.

**5.1 — Dans le portail Apple Developer** (<https://developer.apple.com/account>) :

1. **Certificates, Identifiers & Profiles** ▸ **Identifiers**.
2. Sélectionne l'App ID de StudyTrack (`com.hczr.studytrack.app`) et coche
   **Sign in with Apple**, puis **Save**.
3. **Identifiers** ▸ **+** ▸ **Services IDs** ▸ Continue.
   - Description : `StudyTrack Supabase`
   - Identifier : `com.hczr.studytrack.app.service`
   - **Register**, puis rouvre-le et coche **Sign in with Apple** ▸ **Configure**.
   - **Primary App ID** : celui de StudyTrack.
   - **Return URLs** : `https://<ton-projet>.supabase.co/auth/v1/callback`
   - **Save**.
4. **Keys** ▸ **+** : nomme-la `StudyTrack Supabase`, coche **Sign in with Apple**,
   **Configure** ▸ Primary App ID, **Save**.
   - **Download** le fichier `.p8` — tu ne pourras plus le télécharger ensuite.
   - Note le **Key ID** (10 caractères) et ton **Team ID** (en haut à droite).

**5.2 — Dans Supabase** : **Authentication** ▸ **Sign In / Providers** ▸ **Apple** :

| Champ | Valeur |
|---|---|
| Enable Sign in with Apple | activé |
| Services ID | `com.hczr.studytrack.app.service` |
| Team ID | ton Team ID Apple |
| Key ID | le Key ID de la clé `.p8` |
| Private Key | le **contenu** du fichier `.p8`, `-----BEGIN PRIVATE KEY-----` inclus |

**5.3 — Dans l'app** : `Support/StudyTrack.entitlements` contient déjà
`com.apple.developer.applesignin`. Vérifie dans Xcode ▸ cible **StudyTrack** ▸
**Signing & Capabilities** que la capacité *Sign in with Apple* est bien listée.

> Dans le **simulateur**, Sign in with Apple exige un compte iCloud connecté
> (Réglages ▸ Se connecter à l'iPhone). Sur un appareil réel, tout fonctionne
> directement.

---

## 6. Déployer l'analyse IA des PDF (facultatif)

**À quoi ça sert** : c'est le **moteur principal** de l'analyse des PDF. La clé du
fournisseur de modèle reste côté serveur ; l'app n'utilise que sa clé `anon`, et
l'étudiant·e n'a rien à saisir. Sans cette fonction, l'analyse retombe sur le modèle
de l'appareil, puis sur la lecture par motifs.

> **Ce n'est pas nécessaire si ton appareil a Apple Intelligence** (iOS 26+, Réglages
> ▸ Apple Intelligence activé). **Ce n'est plus le cas par défaut** : l'app essaie
> d'abord la fonction servie, parce qu'un modèle embarqué de quelques milliards de
> paramètres lit nettement moins bien une série réelle. Le modèle de l'appareil sert
> de relais hors ligne, ou si la fonction n'est pas déployée. Vérifie-le dans
> **Profil ▸ Import intelligent ▸ Tester sur cet appareil**.

### 6.1 — Installer la CLI Supabase

```bash
brew install supabase/tap/supabase
supabase login
```

`supabase login` ouvre le navigateur pour autoriser la CLI.

### 6.2 — Déployer la fonction

La CLI cherche la fonction à **`supabase/functions/<nom>/index.ts`**, relativement
au dossier d'où tu lances la commande. Le fichier est donc à la racine du dépôt,
dans `supabase/functions/extract-series/index.ts`.

**Lance la commande depuis la racine du dépôt StudyTrack** :

```bash
cd /chemin/vers/studytrack
supabase functions deploy extract-series --project-ref <ta-ref>
```

`<ta-ref>` est le code du projet, visible dans l'URL du tableau de bord
(`https://supabase.com/dashboard/project/<ta-ref>`) ou dans **Project Settings** ▸
**General** ▸ *Reference ID*.

> **Si tu obtiens `Entrypoint path does not exist`**, c'est que la commande n'a pas
> été lancée depuis la racine du dépôt — la CLI résout un chemin **relatif**.
> Vérifie avec `ls supabase/functions/extract-series/index.ts` : si le fichier n'est
> pas là, tu n'es pas au bon endroit.

### 6.3 — Donner une clé de modèle à la fonction

Le fournisseur par défaut est **Groq**, qui a un palier gratuit largement suffisant.

```bash
supabase secrets set LLM_API_KEY=gsk_ta_cle_groq
```

Le modèle par défaut est **`openai/gpt-oss-20b`**, accessible à un compte gratuit.

> **Un nom de modèle est une donnée extérieure au projet.** Groq fait évoluer ses
> offres : `llama-3.1-8b-instant`, longtemps le défaut naturel, est passé en offre
> **Enterprise** — une clé gratuite n'y a plus accès et reçoit
> `The model … does not exist or you do not have access to it`.
>
> La fonction ne dépend donc plus d'un nom figé : si le fournisseur refuse le modèle,
> elle **demande la liste des modèles disponibles et réessaie une fois** avec le
> meilleur candidat. Elle indique dans sa réponse (`"model"`) celui qu'elle a
> réellement utilisé.

### 6.3 bis — Choisir un autre fournisseur que Groq

Le modèle par défaut est `llama-3.1-8b-instant`, qui n'existe **que** chez Groq. Si tu
changes de fournisseur, tu **dois** donner son nom de modèle — les deux secrets vont
**ensemble** :

```bash
supabase secrets set LLM_BASE_URL=https://openrouter.ai/api/v1
supabase secrets set LLM_MODEL=meta-llama/llama-3.1-8b-instruct:free
```

> **L'erreur à reconnaître** : `502` avec
> `The model \`llama-3.1-8b-instant\` does not exist or you do not have access to it`.
> Elle signifie que l'adresse a changé mais pas le modèle : la fonction envoyait un
> nom Groq à un autre fournisseur. La fonction refuse désormais de partir dans cette
> configuration — elle répond `503` en le disant — et, si le fournisseur renvoie tout
> de même `model_not_found`, elle **liste les modèles disponibles** dans le message.

Pour voir ce que ton projet a réellement comme secrets :

```bash
supabase secrets list
```

Pour revenir à Groq :

```bash
supabase secrets unset LLM_BASE_URL LLM_MODEL
supabase secrets set LLM_API_KEY=gsk_ta_cle_groq
```

**Listes de modèles à jour** : [Groq](https://console.groq.com/docs/models) ·
[OpenRouter](https://openrouter.ai/models) ·
[Mistral](https://docs.mistral.ai/getting-started/models/models_overview/).

### 6.4 — Vérifier

Dans l'app : **Profil ▸ Import intelligent ▸ Vérifier la fonction**.
La ligne doit passer au vert : « Déployée et joignable ».

Ou en ligne de commande :

```bash
curl -X POST "https://<ta-ref>.supabase.co/functions/v1/extract-series" \
  -H "apikey: <ta-clé-anon>" -H "Content-Type: application/json" \
  -d '{"text":"Série 3\nExercice 3.1"}'
```

| Ce que tu vois | Ce que ça veut dire |
|---|---|
| `404 {"code":"NOT_FOUND"}` | La fonction n'est pas déployée → étape 6.2 |
| `503` + `LLM_API_KEY manquante` | Le secret n'est pas posé → étape 6.3 |
| `503` + `LLM_MODEL manquant` | Tu as changé de fournisseur sans donner son modèle → étape 6.3 bis |
| `502` + `model_not_found` | Le nom du modèle n'existe pas chez ce fournisseur → étape 6.3 bis |

Dans l'app, **Profil ▸ Import intelligent** distingue les deux cas : « Pas encore
déployée » n'apparaît **que** si la fonction est absente. Si elle répond mais que
l'analyse échoue, le message le dit — et le détail du serveur est affiché dessous.

> **La fonction consomme des crédits de modèle.** Elle exige la clé `anon`, qui est
> publique : elle écarte les appels sans clé, elle n'authentifie personne. Garde un
> œil sur l'usage chez ton fournisseur.

---

## 7. Erreurs courantes

| Message | Cause réelle | Ce qu'il faut faire |
|---|---|---|
| `PGRST205 Could not find the table 'public.group_members'` | Le SQL n'a jamais été exécuté, **ou** le cache PostgREST est périmé | Exécute `Support/supabase-schema.sql` (il rechargera le cache à la fin) |
| `PGRST202` sur `group_leaderboard` | La fonction de classement manque | Relance `Support/supabase-schema.sql` |
| `42501` sur une **écriture**, `new row violates row-level security policy for table "presence"` | Tu n'es pas membre du groupe côté serveur | Relance une synchronisation : elle rétablit ton adhésion si tu as créé le groupe. Sinon, regarde `Support/supabase-check.sql` |
| `42501 permission denied for table presence` (sur une **lecture**) | Droit de table manquant — rien à voir avec les politiques | Relance `Support/supabase-schema.sql` : il accorde les droits explicitement |
| `23503` — violation de clé étrangère | La ligne `profiles` n'existe pas | Reconnecte-toi : le déclencheur la crée. Le SQL contient aussi un rattrapage |
| `PGRST201` — plusieurs relations trouvées | Ambiguïté d'imbrication | Relance `Support/supabase-schema.sql` |
| Sign in with Apple : `Code=1000` | L'entitlement manque, ou le Service ID n'est pas configuré | Vérifie les étapes 5.1 à 5.3 |
| L'app affiche « Groupes non configurés » | `SUPABASE_HOST` ou `SUPABASE_ANON_KEY` est vide ou mal écrit | Reprends l'étape 2, puis **Clean Build Folder** |
| La fonction IA répond 404 | Elle n'est pas déployée | Étape 6.2 |
| La fonction IA répond 500 | Le secret `LLM_API_KEY` manque | Étape 6.3 |
| `502` avec `The model … does not exist or you do not have access to it` | Le modèle demandé n'est pas accessible à ta clé — le plus souvent passé en offre Enterprise, ou `LLM_BASE_URL` a changé sans que `LLM_MODEL` suive | Redéploie la fonction : elle choisit maintenant un modèle disponible toute seule. Sinon, étape 6.3 bis |

**En cas de doute** : Profil ▸ **Diagnostics**. Le journal local y conserve les
erreurs horodatées, avec le message brut du serveur.

---

## 8. Après une mise à jour de l'app

Si l'app a gagné des tables ou des fonctions, `Support/supabase-schema.sql` a été
mis à jour. **Relance-le** : il est idempotent et n'écrase aucune donnée.

Les tables ajoutées depuis la première version :

| Table | Ce qu'elle porte |
|---|---|
| `item_completion` | L'avancement **exercice par exercice** et **théorie par élément** |
| `group_courses` | Les matières que le groupe travaille |
| `member_courses` | Celles que chaque membre suit |
| `presence` | « Untel travaille sur CS-250 en ce moment » |

---

## 9. Ce que l'app n'envoie jamais

- Aucune donnée de temps de travail n'est publiée pour un cours que le groupe ne
  travaille pas : la durée compte dans le classement, le **code du cours est masqué**.
- L'instantané d'export pour un assistant (`Profil ▸ Données ▸ Exporter pour un
  assistant`) ne contient **ni identifiant, ni jeton, ni adhésion de groupe**.
- La clé `service_role` ne doit jamais quitter le tableau de bord.
