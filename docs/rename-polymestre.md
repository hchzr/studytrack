# StudyTrack → Polymestre : mise en service

Les identifiants ont changé (`ch.polymestre.*`). La reprise copie, vérifie, et ne touche jamais
l'ancien : réinstaller StudyTrack rend tout tel quel. Code : `StudyKit/IdentityMigration.swift`,
`Polymestre/Domain/StoreCopier.swift`, `Polymestre/Domain/IdentityMigrationPlan.swift`,
`windows/src-tauri/src/native/rename.rs`.

## Dans l'ordre

1. **Serveurs** : `scripts/rename-deploy.sh` (additif).
2. **Build pont**, sous l'ancienne identité, depuis le tag `studytrack-bridge` (`main` ne peut plus
   la faire) : `git worktree add ../polymestre-bridge studytrack-bridge`, puis `./release.sh ios`
   là-bas, avec un numéro de build neuf. Chaque testeur l'ouvre une fois : ses réglages privés
   passent dans le groupe d'app. Sans cela, il garde données et connexion mais perd ces réglages.
3. **Portail Apple** : une build signée (`-allowProvisioningUpdates`) a créé les App IDs
   `ch.polymestre.app` (+ `.widgets`, `.share`, `.lock`) et `ch.polymestre.mac`, le conteneur
   iCloud et les groupes (les widgets du Mac n'ont pas d'App ID, comme avant). L'API d'App Store
   Connect refuse le reste, à faire sur developer.apple.com :
   - **MusicKit** (onglet App Services) sur `ch.polymestre.app` et `ch.polymestre.mac` : sans lui,
     Apple Music ne répond pas ;
   - Sign in with Apple sur `ch.polymestre.app` : **groupé avec `com.hczr.studytrack.app`** ;
   - **Family Controls (Distribution)** à redemander pour `ch.polymestre.app` et `.lock`. En
     attendant : `POLYMESTRE_SCREEN_TIME = NO` dans `Support/Supabase.xcconfig`.
4. **App Store Connect** : nouvelle app sur `ch.polymestre.app`, nouveau lien TestFlight.
5. **Schéma iCloud** : une build Debug signée du Mac avec `-initCloudKitSchema`, puis *Deploy
   Schema Changes* vers Production dans la console CloudKit, pour `iCloud.ch.polymestre.app`.
   Le type `IdentityMigration` (le verrou) doit y être : sans lui, la reprise attend.
6. **Essai sur ses propres appareils** : exporter (Profil › Données), installer d'abord sur
   l'appareil utilisé **en dernier** (il a les données les plus fraîches), lire le journal
   (« Données de StudyTrack reprises »), comparer, puis le second appareil. Testeurs ensuite.
7. **Mac** : macOS demande une autorisation par élément du trousseau, une fois. Réinstaller
   l'extension Claude depuis les réglages (« Réinstaller »), puis retirer l'ancienne dans l'app Claude.

## Ce qui garde l'ancien nom, exprès

- Chaînes de dérivation de clés (`studytrack/sync/…`, `pair`, `recovery`, `studytrack.timer.…`,
  `studytrack-group-key-v1`, `studytrack-key-id`, `studytrack-post`) et la graine
  `studytrack.claude.series` : tous les appareils doivent s'accorder dessus ; les changer rendrait
  illisible ce qui est chiffré.
- Identifiant iCloud clé-valeur (`$(TeamIdentifierPrefix)com.hczr.studytrack.app`) : une app n'en a
  qu'un, et rien ne permet d'en recopier le contenu (marques de cours, réglages partagés).
- `source: "StudyTrack"` des webhooks : des automatisations externes peuvent filtrer dessus.
- La clé de réglage `mac.claudeStudyTrackMCP` (réglages repris tels quels).
- `legacyCalendarTitle` : pour renommer le calendrier existant au lieu d'en créer un second.
- Le worker `studytrack-relay` : ses deux adresses mènent à la même instance.
- `com.hczr.studytrack.web`, le Services ID de Sign in with Apple sur Windows : à créer sous
  `ch.polymestre.web` et relancer `supabase/setup-apple-web.sh` si on veut le changer. Invisible.
- Les anciens noms **acceptés en lecture** : `studytrack://`, `studytrack-pair:`, `[StudyTrack]`,
  ```` ```studytrack ````, `studytrack-poly:`, `x-studytrack-install`, `studytrack.json`.

## Pas vérifié

- CloudKit de bout en bout (verrou, envoi de la base copiée, second appareil) : il faut les
  identifiants du portail et de vrais appareils. Testé hors iCloud : copie, vérification, décisions.
- En particulier : que le miroir de SwiftData envoie bien les objets écrits avant sa première
  ouverture. Comportement attendu, à constater à l'étape 6 (console CloudKit).
- La copie Windows sur un vrai Windows (dossiers, WebView2, Credential Manager), et le fait qu'un
  installateur au nouvel identifiant remplace proprement l'ancienne installation.
