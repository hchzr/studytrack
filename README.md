# StudyTrack — suivi du temps d'étude EPFL (iOS)

Application iOS (SwiftUI + SwiftData) qui structure un semestre EPFL, suit la
progression théorie/exercices, mesure le temps de travail réel, le compare à la
charge attendue par l'EPFL, et ajoute des fonctions sociales ainsi que les
intégrations calendrier, horaire et tâches.

- **Cible :** iPhone + iPad, iOS 17+
- **Langue de l'interface :** français
- **Dépendances :** aucune (100 % frameworks système : SwiftUI, SwiftData, EventKit,
  UserNotifications, AuthenticationServices, AppIntents, UIKit)
- **86 fichiers Swift**, ~21 000 lignes (app + widget + code partagé)

> **v2.1.** Une relecture complète de l'app (`AUDIT.md` §0 bis) a corrigé une
> exigence inatteignable — aucun écran ne permettait de **saisir une évaluation** —,
> quatre actions destructrices sans confirmation, un chrono perdu à la fermeture
> de l'app, et ajouté l'historique des sessions, la sauvegarde restaurable, le
> Pomodoro qui sonne, et le graphique des 14 derniers jours.
> La v2 avait déjà corrigé les 6 défauts et 10 carences de la v1, et supprimé Moodle.

---

## 1. Compiler

```bash
./build.sh                      # Debug (simulateur)
CONFIGURATION=Release ./build.sh
```

Ou directement :

```bash
xcodebuild -project StudyTrack.xcodeproj -scheme StudyTrack \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" build
```

> **Pourquoi `-disable-sandbox` ?** Le compilateur Swift exécute les macros
> (`@Model`, `@Observable`, `@State`…) dans un `swift-plugin-server` qu'il encapsule
> dans son propre `sandbox-exec`. Dans un environnement déjà sandboxé, ce sandbox
> imbriqué est refusé (`sandbox_apply: Operation not permitted`) et la compilation
> échoue avec `swift-plugin-server produced malformed response`. Le drapeau désactive
> ce sandbox interne. **Dans Xcode normal, aucun drapeau n'est nécessaire** — ouvrez
> simplement `StudyTrack.xcodeproj`.

### Si Xcode signale un fichier introuvable ou « Multiple commands produce »

Exemple : `Build input file cannot be found: …/StudyTrack/Domain/ColorContrast.swift`,
ou `Multiple commands produce …/<Fichier>.stringsdata`, pour un fichier qui a été
**déplacé**. Le projet est alors sain : c'est la **description de build mise en
cache** dans `~/Library/Developer/Xcode/DerivedData/StudyTrack-*` qui référence
encore l'ancien chemin (et, s'il existe deux fichiers de même nom dans une même
cible, fait produire deux fois le même `.stringsdata`).

`Product ▸ Clean Build Folder` ne supprime **pas** cette description. Il faut
quitter Xcode (⌘Q) — sinon il la réécrit — puis :

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/StudyTrack-*
```

Les dossiers `PBXFileSystemSynchronizedRootGroup` (`StudyTrack/`, `StudyTrackWidgets/`,
`Shared/`) sont résolus à l'ouverture du projet : rouvrez et recompilez.

### Vérifier la logique métier

La validation exécutable compile `Models/` + `Domain/` + les services d'import en un
binaire macOS et teste :

- le schéma SwiftData (13 entités) et les relations inverses ;
- les moteurs de progression, de charge EPFL et de gamification ;
- le **parseur iCalendar** (occurrences hebdomadaires, fuseaux, `BYDAY`) ;
- l'**import d'horaire** (cours reconnu vs créé, section, détection « a un cours ») ;
- l'**import CSV** (vidéos, exercices, bonus, évaluations) ;
- le **bornage de la semaine** et le planificateur du jour ;
- la **persistance du chrono** (`FocusTimerState` : pause, reprise, restauration) ;
- les **agrégats de sessions** (totaux par jour, historique) ;
- la **sauvegarde** : export → import dans un conteneur vierge, progression
  identique, réimport sans doublon ; format d'heures du widget.

```bash
./validate.sh     # se termine par « ✅ TOUS LES CONTRÔLES SONT PASSÉS »
```

`./validate.sh --bench` ajoute des **repères de performance** : il construit un
semestre simulé (6 cours, 240 vidéos, 576 exercices, 480 sessions) et chronomètre
les dérivations que les écrans refont à chaque rendu. La mesure porte sur la logique
pure (`Domain/`), pas sur le rendu SwiftUI.

### Relire l'interface dans le simulateur

Un simulateur iOS est installé : l'app se lance et se capture réellement.

```bash
xcodebuild -project StudyTrack.xcodeproj -scheme StudyTrack -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/simbuild \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" build

xcrun simctl install booted /tmp/simbuild/Build/Products/Debug-iphonesimulator/StudyTrack.app
xcrun simctl launch booted com.hczr.studytrack.app -seedSampleData -tab 0
xcrun simctl io booted screenshot /tmp/today-ipad.png
```

`xcrun simctl` ne sait pas taper dans l'interface, et ouvrir un lien profond
déclenche un « Ouvrir dans StudyTrack ? » qu'on ne peut pas confirmer. Ces
arguments, **compilés en Debug seulement** (`PreviewLaunch`), rendent donc chaque
écran atteignable :

| Argument | Effet |
|---|---|
| `-seedSampleData` | installe le semestre d'exemple, saute l'accueil, et supprime le prompt de notifications qui recouvrirait la capture |
| `-tab <0…4>` | ouvre directement un onglet (0 Aujourd'hui, 1 Cours, 2 Focus, 3 Groupes, 4 Agenda) |
| `-course <code>` | présélectionne un cours dans le volet de droite (`-course CS-250`) |
| `-courseTab <theory\|exercises\|progress\|agenda>` | avec `-course`, ouvre cet onglet de la fiche |
| `-onboardingStep <0…3>` | ouvre une étape de l'accueil — à lancer sur une installation **fraîche**, le seeding marquant l'accueil comme terminé |
| `-profile` | ouvre « Profil & réglages » : les onze écrans de configuration sont autrement inatteignables sans taper |
| `-school` | avec `-profile`, ouvre « Section et semestre » (section, cours, dates) |
| `-stats` | ouvre « Statistiques » (feuille depuis « Aujourd'hui ») |
| `-group <index>` | ouvre la fiche du groupe à cet index (`-tab 3` requis) |
| `-groupSubject <code>` | avec `-group`, ouvre l'avancement d'une matière (`-groupSubject CS-250`) |
| `-groupInvite` | avec `-group`, ouvre la feuille d'invitation (QR code et lien) |
| `-groupSubjects` | avec `-group`, ouvre l'éditeur des matières du groupe |
| `-groupPage <members\|time\|series\|planning>` | avec `-group`, ouvre une sous-page de la fiche |
| `-importFile <chemin absolu>` | ouvre l'import de série sur ce PDF, comme un partage depuis une autre app (le simulateur non signé n'a pas de conteneur de groupe) |
| `-breakTermLink` | **casse** le lien cours ↔ semestre (et remet les séries à la semaine 1) pour vérifier la réparation au lancement suivant |
| `-breakGroupRole` | **rétrograde** le créateur du groupe à « membre », pour vérifier qu'il garde ses droits |

Pour repartir d'un état vierge : `xcrun simctl erase <udid>` (le prompt système
d'une capture précédente survit à une simple désinstallation).

Ces arguments ouvrent un écran, pas une **feuille dans une feuille** : ce qui est
sous la ligne de flottaison d'un formulaire, ou derrière un second tap, reste hors
de portée d'une capture automatique. C'est une limite connue de cette méthode.

---

## 2. Parcours utilisateur

### Premier lancement : accueil guidé (et non plus des cours fictifs)

1. **Ta section** — tu choisis ta section EPFL (IN, MA, PH, SC, GM, AR… 28 sections
   avec leur faculté).
2. **Tes cours** — tu importes ton horaire `.ics`, un JSON/CSV, ou tu saisis tes
   cours. Pour **chaque classe**, deux interrupteurs : « suivie » et
   **« a un cours (amphi) »**.
3. **Ton semestre** — dates de début et durée, pour que le suivi hebdomadaire soit juste.

Aucune donnée n'est inventée. Un bouton explicite « Essayer avec des données
d'exemple » ajoute un semestre de démonstration si on le souhaite.

### Les cinq onglets

| Onglet | Rôle |
|---|---|
| **Aujourd'hui** | La prochaine chose à faire (avec un bouton « Démarrer le chrono »), ce qui reste cette semaine, les échéances, la progression |
| **Cours** | Ton plan : une carte par cours, puis Théorie / Exercices / Progression / Agenda |
| **Focus** | Chrono catégorisé, mode Pomodoro, saisie manuelle, journal du jour |
| **Groupes** | Une fiche qui **oriente** (direct, trois chiffres, matières) vers quatre sous-pages : **Avancement des séries** (série par série, membre par membre, numéros faits écrits), **Temps d'étude** (classement 7 j / total, ma place), **Membres** (rôles, gestion par glissement), **Sessions planifiées** (RSVP) |
| **Agenda** | Une **bande de semaine** à balayer (pastilles colorées sous les jours chargés), la journée choisie en timeline (heure, barre de couleur du cours, présence à cocher), puis « Ensuite » (les 8 prochains éléments). Filtres par famille, planification depuis le jour choisi, menu contextuel pour terminer une tâche ou supprimer une session |

---

## 3. Ce qui est implémenté

### Décomposition et suivi

| Exigence | Où |
|---|---|
| Décomposition de la théorie (`vidéo 1.1`, `chapitre 2.3`…) + durée | `TheoryItem` typé par `TheoryKind` — **vidéo, lecture, chapitre, diapositives**. Un cours **sans aucune vidéo** est un cas normal, pas une exception : la durée est facultative et n'est jamais inventée. Onglet **Théorie** |
| Durée de théorie à faire **par semaine** | carte « Théorie cette semaine », `ProgressEngine` |
| Décomposition par sous-exercices (`exercice 1.1`) + **bonus** | `ExerciseSeries` / `Exercise` |
| **Date de visionnage** | `TheoryVideo.watchedAt` |
| **Date de résumé** | `TheoryVideo.summarizedAt` + texte du résumé |
| **Date** de l'exercice + **code couleur vert/orange/rouge** | `Exercise.doneAt` + `ConfidenceControl` — **contrôle à trois pastilles toujours visible**, plus caché dans un menu |
| **Date de correction** + juste / moyennement juste / faux + **à refaire** | `Exercise.correctedAt`, `CorrectnessControl`, `redoRequired` (auto si « faux ») |
| **Pourcentages** théorie / exercices / corrections **par semaine** | onglet **Progression**, graphique **à défilement horizontal** (14 semaines ne tiennent pas sur un écran) |
| **Feuille récapitulative** + gamification | `StatsView` (anneaux par cours, XP, niveaux, badges) |
| **Agenda** avec midterms / examens | `Exam`, saisis dans **Cours › Agenda › Ajouter une évaluation** (`ExamFormSheet` : type, date, lieu, pondération), avec rappels J-3 et J-1. Onglet Agenda du cours et onglet Agenda global |

### Temps et charge EPFL

| Exigence | Où |
|---|---|
| Tracker par **sous-catégorie** (matière × type : exo, vidéo, théorie, flashcards…) | `StudySession`, onglet **Focus** |
| **Catégorisation fine** : sur quel exercice, quelle vidéo, quel chapitre | `StudySession.exercise` / `StudySession.theoryItem`, choisis dans « Sur quoi ? ». Facultatif : une session non précisée reste valide, et le journal affiche la cible quand elle est connue |
| **Chrono qui survit** à une fermeture de l'app | `FocusTimerState` écrit dans `UserDefaults` à chaque changement d'état ; au relancement, le temps écoulé est compté. Au-delà de 18 h, la session est enregistrée bornée et signalée dans l'historique. « Aujourd'hui » affiche un bandeau « Chrono en cours » tant qu'il tourne |
| **Pomodoro** qui prévient | Notification locale à la fin du bloc (écran verrouillé compris), haptique et proposition de pause si l'écran est ouvert |
| **Historique des sessions** modifiable | `SessionHistoryView` : jour par jour, filtre par cours, modification (cours, type, cible, début, durée, note), suppression, export CSV |
| Récap visuel **jour / semaine / mois** | `StatsView` |
| **Temps prévu EPFL vs effectué**, par matière, cours/exos séparés, **heures de cours incluses** | `WorkloadEngine` — l'attendu est **hebdomadaire**, jamais semestriel : heures d'amphi et d'exos saisies par cours, plus un objectif de travail personnel par semaine (déduit des ECTS, ou fixé à la main). La part amphi vaut **zéro** pour un cours déclaré sans cours ; la présence réelle se coche dans l'agenda |
| **Renommer / abréger un cours** | `Course.shortName` (éditable dans le formulaire) et `Course.displayCode`, utilisé partout où la place manque — l'abréviation remplace le code sans jamais écraser le code officiel |

### Intégrations

| Intégration | État | Détail |
|---|---|---|
| **Horaire EPFL (.ics)** | ✅ **nouveau, chemin principal** | `ICSParser` (RFC 5545 : `VEVENT`, `TZID`, `RRULE` hebdo/quotidienne, `BYDAY`, `EXDATE`), import par URL (`https://`, `webcal://`), fichier ou copier-coller. Crée les cours, **détecte ceux qui ont des heures de cours**, lie les séances, et est idempotent (par `UID`). |
| **Calendrier Apple** (EventKit) | ✅ | Import, liaison automatique aux cours par code, création de sessions planifiées. Une session planifiée est écrite dans un calendrier « StudyTrack » et supprimée avec elle |
| **Rappels Apple** | ✅ | Lecture, création, terminaison, suppression |
| **Todoist** | ✅ | API unifiée v1 (`api.todoist.com/api/v1`) |
| **Things 3** | ✅ **nouveau** | Schéma d'URL, écriture seule (signalé comme tel dans l'interface) |
| **Notion** | ✅ **nouveau** | Base de données de tâches (propriétés `Name`, `Done`, `Due`) |
| **Webhook générique** | ✅ **nouveau** | POST JSON — compatible Raccourcis, Home Assistant, Zapier, n8n |
| **Microsoft To Do** | ✅ **nouveau, non vérifié sur un compte réel** | Microsoft Graph (`/me/todo`), jeton d'accès saisi par l'étudiant·e — il expire en une heure environ |
| **Google Tasks** | ✅ **nouveau, non vérifié sur un compte réel** | API Tasks v1 avec **refresh token** : l'app renouvelle elle-même son jeton d'accès, gardé en mémoire |
| **TickTick** | ✅ **nouveau, non vérifié sur un compte réel** | API ouverte v1 (`api.ticktick.com/open/v1`), jeton OAuth2 |
| **Notice par intégration** | ✅ **nouveau** | Bouton « Comment configurer ? » sur chaque fournisseur : résumé, capacité, étapes numérotées, lien vers la page des identifiants et limite propre. `validate.sh` refuse un fournisseur sans notice |
| **Siri / Raccourcis (App Intents)** | ✅ **nouveau** | « Démarre une session », « Enregistre une session », « Ajoute une tâche », « **Planifie une session** » (écrite au calendrier) et « **Marque un exercice comme fait** » (avec la sureté) — métadonnées `Metadata.appintents` générées |
| **Widgets d'écran d'accueil** | ✅ | Cible d'extension `StudyTrackWidgets` (petit / moyen / grand) : temps de la semaine, série, à-faire, prochaine évaluation + un widget compact « temps de travail ». Un tap ouvre l'écran correspondant. Données partagées via l'App Group `group.com.studytracker.app` |
| **Live Activity** (écran verrouillé, îlot dynamique) | ✅ | `StudyActivityWidget` : le chrono en cours, avancé par le système (`Text(timerInterval:)`), état « en cours / en pause » |
| **Liens profonds** | ✅ | `studytrack://focus?course=CS-250&type=exercise`, `://today`, `://tasks`, `://stats`, `://agenda`, `://courses`, `://groups`, **`://join?code=EPFL-XXXX`** (ouvre « Rejoindre » pré-rempli) |
| **Sauvegarde / restauration** | ✅ **nouveau** | Profil › Données › *Créer une sauvegarde* produit un JSON **réimportable** (structure + avancement + sessions). Restauration par Importer › JSON, idempotente. Export CSV des sessions pour un tableur |
| **Import JSON / CSV** | ✅ | Idempotent (upsert par code de cours / numéro) |
| **Import PDF des séries** | ✅ | Lecture **par ligne avec la taille de police** (`PDFLayoutExtractor` + `SeriesLayoutParser`) : un titre se distingue d'un énoncé, ce que le texte aplati ne permettait pas. Les exercices sont numérotés **par leur série** (« Exercice 1 » de la Série 2 → « 2.1 »). `SeriesPDFParser` reste le repli pour le texte collé, sans mise en page. **Toujours suivi d'un écran de relecture** : on coche, on corrige le bonus, on crée. Un PDF **scanné** est annoncé comme tel plutôt que de laisser croire à un échec |
| **Import PDF assisté par IA** | ✅ **nouveau** | `SeriesAIExtractor` : le texte est **d'abord** lu par les motifs, puis **complété** par un modèle de langage, **routé automatiquement et sans rien demander à l'étudiant·e** : (1) la **fonction Supabase** `extract-series` — un modèle **servi**, la clé du fournisseur reste côté serveur et l'app n'utilise que sa clé `anon` ; (2) **sur l'appareil** — Apple Intelligence / FoundationModels, iOS 26, **relais hors ligne** ; (3) un **service perso** (URL + clé, compatible OpenAI) si l'étudiant·e en a saisi un. **Le service passe avant le modèle embarqué** : sur une série réelle, l'écart de qualité n'est pas marginal — l'ordre est épinglé par des tests (`SeriesEngineOrder`). Un maillon qui échoue passe au suivant. La fusion (`SeriesAIParsing.merge`, testée) ne retire jamais un numéro lu par les motifs ; on peut revenir aux motifs d'un tap. Plusieurs PDF à la fois, ou un énoncé **collé** (Moodle, mail). Réglages : Profil › Import intelligent | Réglages : Profil › Import intelligent |
| **Ce que l'IA garantit** | ✅ **nouveau** | Une consigne explicite et testée : **un titre pour chaque exercice**, jamais vide — le modèle en écrit un de 2 à 6 mots à partir du titre de section quand le PDF n'en donne pas ; **dans la langue du document** (un PDF français donnait des titres anglais) ; et **un numéro qualifié par la série**, même quand le PDF recommence à 1 dans chaque section. Un exercice **sans aucun numéro** reçoit le suivant libre au lieu d'être jeté. La lecture de la réponse est **tolérante** : un modèle qui écrit `"02a"` au lieu de `2`, ou `"oui"` au lieu de `true`, ne fait plus perdre la réponse entière |
| **Sous-questions** | ✅ **nouveau** | Un polycopié numérote souvent ses exercices 1, 2, 3 **dans chaque section**, et regroupe plusieurs questions sous un seul numéro. Le modèle `SubQuestion` porte ces questions : chacune se coche, l'exercice devient fait quand elles le sont toutes, et la série, la progression et les statistiques continuent de compter des **exercices**. Un compteur « 2/3 » se lit dans la liste sans ouvrir. L'IA les détecte et les regroupe ; l'import les crée sans jamais dupliquer ce qui existe |
| ~~Moodle (web service)~~ | ❌ **supprimé** | L'EPFL ne délivre pas de jeton de service web aux étudiant·e·s : ce connecteur ne pouvait jamais s'authentifier. Remplacé par l'import `.ics`. |

### Chrono et Live Activity

| Fonction | État | Détail |
|---|---|---|
| **Compteur de la Live Activity** | ✅ **corrigé** | Il repartait de zéro à chaque reprise : l'état portait le total **et** l'instant de reprise, et le compteur système n'affichait que le second — « 00:01 » après une heure de travail. L'instant de départ est désormais **reculé du total écoulé** (`ActivityTimerState`, pur et testé) |
| **Îlot compact** | ✅ **corrigé** | Les régions qui entourent la caméra ne portent plus qu'une **icône** : y écrire « en cours » ou le code du cours élargissait l'îlot. Le compteur s'écrit en `MM:SS`, sans les heures |
| **Ajuster le chrono** | ✅ **nouveau** | Roue heures + minutes pour corriger le temps compté en cours de session : on lance le chrono en oubliant de le lancer avant, ou on le laisse tourner pendant une interruption |
| **Éditer une session** | ✅ **refait** | Roues pour le début et la durée, au lieu d'un sélecteur compact et d'un pas-à-pas. Corriger « 1 h 05 au lieu de 40 min » demandait treize taps |
| **Pomodoro visible** | ✅ **refait** | Une pastille sur la carte du chrono, avec la durée du bloc et de la pause. C'était un interrupteur enterré dans « Catégorisation », dont rien n'indiquait l'état |
| **Analyse IA testable** | ✅ **nouveau** | Un bouton « Tester sur cet appareil » à côté de « Vérifier la fonction » : on sait enfin **quel** moteur répond, et s'il répond. Un échec de l'IA s'affiche en orange dans l'écran d'import au lieu d'une remarque grise |

| Fonction | État | Détail |
|---|---|---|
| **Cadran du chrono** | ✅ **refait** | Anneau de progression teinté par le cours, temps au centre, contexte et état Pomodoro. Un anneau **situe** la session là où un texte la laissait abstraite |
| **Hiérarchie des actions** | ✅ **refait** | Un disque pour l'action qu'on fait dix fois par session (pause/reprise), des boutons discrets pour celles qu'on fait une fois. Et un bouton **Abandonner** — il n'existait aucun moyen de renoncer à une session lancée par erreur |
| **Pomodoro lisible** | ✅ **refait** | `PomodoroEngine` (pur, 18 cas testés) : numéro de bloc, blocs terminés, temps restant, progression de l'anneau. Le bloc n'était annoncé que par une notification, jamais à l'écran |
| **Raccourcis composables** | ✅ **refait** | Ils étaient une grille **fixe** de tous les cours × trois types (douze tuiles sur quatre cours, non modifiables). C'est maintenant une liste que l'on compose, ordonne et nettoie (`FocusShortcutsEditor`). Un cours supprimé ne laisse plus de tuile morte |
| **Îlot dynamique compact** | ✅ **refait** | La forme repliée se contente d'une **icône de largeur fixe** et du temps : y écrire le code du cours élargissait l'îlot en permanence. Le cours vit dans la forme dépliée, qui ne coûte rien tant qu'on ne la déplie pas |
| **Contrôles sur l'écran verrouillé** | ✅ **nouveau** | Boutons **pause / reprendre / enregistrer** dans la Live Activity et l'îlot, via `LiveActivityIntent` : ils s'exécutent dans le processus de l'app, donc enregistrer une session ne demande pas d'ouvrir l'app. La commande passe par un dépôt partagé, et une commande déposée pendant que l'app dormait est rejouée au retour au premier plan |
| **Support Live Activity déclaré** | ✅ **corrigé** | `NSSupportsLiveActivities` manquait dans l'Info.plist de l'**extension widget** — celle qui affiche l'activité. L'app le déclarait, pas l'extension : la Live Activity ne s'affichait donc jamais |

### Live Activity et îlot

| Ce qui est vrai | Détail |
|---|---|
| L'activité est **créée** | Vérifié au simulateur : `activité créée <id> — 1 vivante(s)` dans le journal unifié |
| L'îlot replié | Un icône d'état à gauche, le **temps** à droite. Vider ces deux régions ne rétrécit pas l'îlot : il n'affiche **plus rien** |
| L'intervalle du chrono est **borné** | `Text(timerInterval:)` réserve la largeur du plus grand texte de l'intervalle ; `Date.distantFuture` faisait réserver une place démesurée |
| Diagnostic | Profil › **Diagnostics** › « Îlot et écran verrouillé » : activités en cours, dernier refus, et un bouton **« Lancer une activité d'essai »** |


### Plan, annales, session partagée

| Fonction | État | Détail |
|---|---|---|
| **Plan de révision** | ✅ **nouveau** | `RevisionEngine` (pur, 30 cas testés) répartit ce qui reste entre aujourd'hui et l'évaluation : ordre du cours respecté (théorie, exercices, corrections, semaine après semaine), **un cinquième des jours réservé à la relecture**, et un contrôle de réalisme contre le temps disponible par jour |
| **Annales** | ✅ **nouveau** | Les sujets passés sont enfin suivis : année, lien du sujet, lien du corrigé, travaillé ou non, sureté, notes. Bilan « 2/4 travaillées » et priorité aux années récentes. Pas de note — l'app suit le travail, pas les résultats |
| **Session partagée** | ✅ **nouveau** | « Rejoindre » sur la présence d'un membre : ton chrono démarre sur le même cours, avec la même nature de travail. Aucun changement serveur — la présence portait déjà tout ce qu'il faut |
| **Journal local** | ✅ **nouveau** | `AppLog` + écran Diagnostics : erreurs de synchronisation, d'IA, de stockage et d'Anki, horodatées et exportables. Tampon borné qui **garde les erreurs** plus longtemps que les informations |
| **Annulation d'import** | ✅ **refait** | Un PDF de trente pages peut prendre une minute : bandeau de progression avec un bouton **Arrêter** visible, et la lecture par motifs est toujours conservée |

### Recherche

| Fonction | État | Détail |
|---|---|---|
| **Recherche globale** | ✅ **nouveau** | `SearchEngine` (pur, 40 cas testés) indexe cours, séries, exercices, théorie, évaluations, sessions de travail, tâches, échéances de l'EPFL et groupes. **Insensible aux accents et à la casse** (« algebre » trouve « Algèbre »), **tolérante au code collé** (« cs250 » et « cs 250 » trouvent CS-250), et **tous les mots doivent correspondre** — « algo exo 3 » ne ramène pas tout ce qui contient « algo ». Chaque résultat annonce **pourquoi** il sort (intitulé, détail ou code du cours) et mène directement au bon onglet du cours. Accessible par la loupe d'« Aujourd'hui » et de « Cours » |

### Vie de l'EPFL

| Fonction | État | Détail |
|---|---|---|
| **Calendrier académique officiel** | ✅ **nouveau** | Les 71 échéances publiées par l'EPFL (bornes d'enseignement, sessions d'examens, vacances, jours fériés, délais, publications) sont **relevées sur la page publique** puis embarquées : l'app les connaît hors ligne, dès l'installation, y compris le jour de la rentrée. Écran « Vie de l'EPFL » : semaine courante, prochaine échéance structurante, délais à ne pas manquer, vacances, déroulé du semestre, et ajout d'échéances personnelles. Un bouton **relit la page** pour rafraîchir |
| **Rentrée sourcée** | ✅ **nouveau** | `DateUtils.autumnStart` consulte la date **publiée** par l'EPFL avant d'appliquer la règle du premier lundi dès le 7 septembre. Si l'école décale une rentrée, l'app suit sans toucher au code |
| **Dates approximatives assumées** | ✅ **nouveau** | L'EPFL écrit « Fin décembre », « Mi-novembre », « Début mars ». L'app choisit le dernier jour, le 15 ou le 1er, et affiche **« approximatif »** plutôt que de faire passer une estimation pour une date exacte |
| **Source relisible** | ✅ **nouveau** | `AcademicCalendarParser` (pur) lit le HTML de la page — balises, entités nommées **et** numériques. Testé sur un extrait **authentique** de la page. `AcademicCalendarService.refresh` met à jour sans dupliquer (clé stable) et retire les échéances officielles à venir qui ne sont plus publiées |

### Suivi : ce qui manque

| Fonction | État | Détail |
|---|---|---|
| **Couverture du suivi** | ✅ **nouveau** | `CoverageEngine` (pur, 28 cas testés) audite tout : cours vide, série sans exercice, série en retard, exercice fait non corrigé, exercice à refaire, théorie vue sans résumé, théorie sans durée, évaluation absente, semestre ou horaire manquants. Écran « Couverture du suivi » depuis Statistiques : pourcentage de cours sans aucun manque, constats groupés par famille avec le **code du cours** à côté, et chaque ligne mène au cours concerné |

### Social

| Fonction | État | Détail |
|---|---|---|
| **Matières multiples par groupe** | ✅ **nouveau** | Un groupe déclare **plusieurs** matières (avant : un seul code optionnel). Les administrateurs définissent la liste, chaque membre coche celles qu'il suit — et seul l'avancement de ces matières est partagé |
| **Avancement lisible par matière** | ✅ **nouveau** | Un écran par matière : rang, avancement global, séries / exercices / théorie par membre, et l'**écart avec toi** (« 3 éléments d'avance »). Un sélecteur choisit l'axe mis en avant |
| **Présence en direct** | ✅ **nouveau** | « Alice travaille sur CS-250 · Exercices · 3.2, depuis 1 h 12 », avec un battement toutes les 5 min. Un membre dont le battement date est éteint tout seul — pas de fausse présence |
| **Invitations** | ✅ **nouveau** | Code, **lien** `studytrack://join?code=…` (reconnu par l'app) et **QR code** généré par CoreImage. Feuille de partage système |
| **Rôles visibles** | ✅ **nouveau** | Pastille « Admin » sur les administrateurs ; nommer / rétrograder / retirer depuis la fiche, dans la limite des politiques RLS |
| **Quitter un groupe** | ✅ **nouveau** | Bouton explicite dans la fiche (distinct de « Supprimer le groupe », réservé aux administrateurs), avec avertissement si tu es le dernier admin |
| Classement du temps d'étude | ✅ | 7 derniers jours, calculé côté serveur (`group_leaderboard`) |
| Matrice d'avancement des séries | ✅ | En complément de la vue par matière |
| Planning partagé + RSVP | ✅ | Sessions d'étude planifiées, écrites aussi au calendrier |
| Sign in with Apple + e-mail | ✅ | Supabase Auth |

**Réparation de l'adhésion.** Si l'insertion de ton adhésion a échoué à la
création du groupe, celui-ci existe côté serveur **sans toi** : il n'apparaît plus
dans `fetchMyGroups`, l'avancement ne remonte pas, et publier ta présence est refusé
par `is_group_member` (`42501`). La synchronisation détecte cet état pour les groupes
que **tu as créés** et rétablit ton adhésion d'administrateur. Pour un groupe que tu
as rejoint et dont on t'a retiré, elle ne fait rien : une exclusion doit tenir.

Deux fichiers SQL dans `Support/` :

| Fichier | Rôle |
|---|---|
| `supabase-schema.sql` | à **exécuter** — tables, index, RLS, droits, déclencheurs. Idempotent |
| `supabase-check.sql` | à **lire** — vérifie l'état réel (adhésions, tables, politiques, droits). Lecture seule |

**Session conservée.** La session Supabase est stockée dans le **trousseau** et
rafraîchie automatiquement (`SupabaseSessionStore`, `StoredSession`). Sans ça, le
jeton ne vivait qu'en mémoire : chaque relance de l'app déconnectait en silence, les
groupes cessaient de se synchroniser et la présence ne se publiait plus — sans
qu'aucune erreur ne soit visible. Un jeton expiré est rafraîchi **avant** la requête,
et une réponse 401 déclenche un rafraîchissement puis un nouvel essai.

**Présence : ce qui s'arrête et ce qui continue.** Le battement s'interrompt quand
l'app passe en arrière-plan trop longtemps (téléphone verrouillé) : les autres
cessent alors de te voir « en direct » au bout de ~12 minutes, alors que le chrono,
lui, continue de compter. La durée enregistrée reste juste — seule la présence
s'éteint. C'est volontaire : annoncer quelqu'un comme « en train de travailler »
sans preuve serait pire que de ne rien dire.

---

## 4. Défauts corrigés (voir `AUDIT.md`)

| # | Défaut | Correction |
|---|---|---|
| D1 | Le README annonçait un import CSV inexistant | CSV réellement implémenté (`CourseImporter.importCSV`) + tests |
| D2 | Le graphique hebdomadaire débordait au-delà de ~6 semaines | Défilement horizontal, colonnes de largeur fixe |
| D3 | Numéro de semaine global → écrans vides après un import de semestre ancien | Semaine **par cours**, bornée à la durée du semestre (`DateUtils.clampedWeek`) |
| D4 | `EKEventStore` réinstancié à chaque tap | `TaskServiceFactory` : une instance par fournisseur |
| D5 | Des cours fictifs injectés au premier lancement | Accueil guidé ; les données d'exemple sont **demandées explicitement** |
| D6 | Progression fictive pré-remplie | Idem : plus rien n'est pré-rempli sans accord |

Lourdeur corrigée : rangée d'exercice à ~11 éléments → 4 (coche, identifiant,
surete, chevron) ; sureté cachée dans un menu → contrôle visible ; cibles tactiles
de ~20 pt → 44 pt ; `EditCourseView` confus → `CourseFormView` unique avec « + »
dans chaque onglet ; matrice de groupe illisible → complétée par une **vue par matière** (et une carte « Matières » qui ne l'empile plus) ;
ajout d'haptiques, de menus contextuels, d'états vides actionnables.

---

## 5. Configuration

Tout est optionnel : **l'app fonctionne entièrement hors ligne**.

- **Section, cours et dates du semestre** : Profil › **Section et semestre** —
  tout ce que l'accueil guidé a demandé reste modifiable après coup, **y compris la
  date de début du semestre**, qui commande le numéro de semaine affiché partout.
- **Horaire** : Profil › Calendrier et horaire › *Importer un horaire / JSON / CSV*.
  L'URL du flux est mémorisée pour un réimport en un tap.
- **Tâches** : Profil › Tâches › **Fournisseurs de tâches** — un écran dédié, un
  bloc par fournisseur, avec l'état, l'aide et un bouton **Tester** qui interroge
  réellement le service.
- **Groupes (Supabase)** : la configuration est **compilée dans l'app**, pas saisie
  par l'utilisateur. Voir « Relier les groupes » ci-dessous ; le schéma SQL est en
  section 7 du `SPEC.md`.
- **Charge EPFL** : Profil › Charge de travail (heures par crédit ECTS).

> **Le mode opératoire complet est dans [`Support/SUPABASE.md`](Support/SUPABASE.md)** :
> création du projet, clés, SQL, vérification, connexion, déploiement de la fonction
> IA, et un tableau des erreurs courantes avec leur cause réelle.

### Relier les groupes (configuration de build)

L'URL du projet Supabase et la clé `anon` ne sont **jamais demandées à
l'utilisateur** : ce sont des constantes de build. Les saisir dans les réglages
obligeait chaque étudiant·e à les trouver avant de pouvoir se connecter — alors que
la clé `anon` est publique par conception, puisqu'elle n'autorise que ce que les
politiques RLS de la base permettent.

1. Édite **`Support/Supabase.xcconfig`** — c'est un simple fichier texte, visible
   dans le navigateur Xcode sous le groupe racine. Deux lignes à remplir :
   `SUPABASE_HOST` (le domaine du projet, **sans** `https://`) et `SUPABASE_ANON_KEY`.
2. Exécute **`Support/supabase-schema.sql`** dans Supabase ▸ SQL Editor. Ce fichier
   contient tout : les tables du `SPEC.md` §7.1, la fonction de classement
   `group_leaderboard` (appelée par le code mais absente du SPEC), le déclencheur
   qui crée le profil à l'inscription, les politiques RLS du §7.3, et le
   rechargement du cache PostgREST. Il est idempotent.
3. Rien d'autre : ce fichier est la configuration de base du projet, `Support/Info.plist`
   l'injecte (`SupabaseHost`, `SupabaseAnonKey`) et `SupabaseConfig` compose l'URL au
   lancement.

> **Pourquoi le domaine sans `https://` ?** Un fichier `.xcconfig` considère `//`
> comme le début d'un commentaire : `https://xyz.supabase.co` y serait tronqué à
> `https:`. Le schéma est donc ajouté par le code.

**Une build sans ces valeurs reste pleinement utilisable.** Le suivi des cours, le
temps de travail, l'agenda et les widgets fonctionnent ; seuls les groupes sont
indisponibles. L'écran Compte l'annonce alors explicitement — *« Groupes non
configurés dans cette version »* — au lieu d'afficher deux champs que personne ne
peut remplir. `validate.sh` vérifie qu'une valeur absente, vide, ou restée littérale
(`$(SUPABASE_URL)`) n'est jamais prise pour une configuration.

### Analyse des PDF par IA : déployer la fonction Supabase (une fois)

> **À vérifier avant tout** : Profil › Import intelligent affiche l'état **réel** de
> la fonction. S'il dit « Pas encore déployée », l'import se rabat sur la lecture
> par motifs — ce n'est pas une panne, c'est une fonction jamais installée.

Pour que l'analyse fonctionne **sans jeton** chez les étudiant·e·s dont l'appareil n'a
pas Apple Intelligence, la clé du fournisseur vit dans une Edge Function du projet
Supabase — jamais dans l'app :

```bash
supabase link --project-ref <ref>
supabase functions deploy extract-series --project-ref <ref>
supabase secrets set LLM_API_KEY=gsk_…                                 # Groq : palier gratuit
supabase secrets set LLM_BASE_URL=https://api.groq.com/openai/v1       # facultatif (défaut)
supabase secrets set LLM_MODEL=llama-3.1-8b-instant                    # facultatif (défaut)
```

Le code est dans `supabase/functions/extract-series/index.ts` ; n'importe quelle
API compatible OpenAI convient (OpenRouter avec un modèle `:free`, Mistral…). Sans
déploiement, l'app le détecte (HTTP 404) et passe au maillon suivant.

### Widgets : App Group à enregistrer

L'app et l'extension widget partagent leurs données via l'App Group
**`group.com.studytrack.app`**. Pour que le widget affiche quelque chose sur un
appareil réel :

1. Dans le portail Apple Developer, créez un App Group `group.com.studytracker.app`
   et ajoutez-le aux *deux* identifiants (`com.hczr.studytrack.app` et
   `com.hczr.studytrack.app.widgets`).
2. Les entitlements sont déjà fournis (`Support/StudyTrack.entitlements` et
   `Support/StudyTrackWidgets.entitlements`) et référencés par les deux cibles.

Sans App Group, l'app fonctionne normalement : `WidgetBridge.write` est simplement
un no-op et le widget affiche « Ouvre StudyTrack » au lieu de planter.

> L'identifiant est défini une seule fois (`STUDYTRACK_APP_GROUP` dans le projet)
> et injecté dans les deux `Info.plist` et les deux entitlements.

L'app publie l'instantané quand elle passe au premier plan / arrière-plan
(`WidgetSnapshotWriter`, appelé depuis `RootTabView`) et recharge les timelines.

### Sign in with Apple (appareil réel)

L'entitlement `com.apple.developer.applesignin` est **déjà déclaré** dans
`Support/StudyTrack.entitlements`. Il reste deux choses à faire, qui ne sont pas dans
le dépôt :

1. **Portail Apple Developer** — active « Sign in with Apple » sur l'identifiant
   `com.hczr.studytrack.app`. Avec la signature automatique, Xcode le fait pour toi au
   premier build signé ; si le build échoue à signer, c'est que l'identifiant est géré
   ailleurs.
2. **Supabase** — Authentication ▸ Providers ▸ Apple : renseigne le *Service ID*, la
   *Team ID*, le *Key ID* et la clé `.p8`.

**Dans le simulateur, il faut en plus être connecté à iCloud** (Réglages ▸ Se connecter
à votre iPhone). Sans compte iCloud, `ASAuthorizationController` échoue avec
`Code=1000 "(null)"` — l'erreur la plus opaque d'Apple, et la plus fréquente.

Sans compte Apple Developer, la connexion e-mail/mot de passe Supabase fonctionne et
le bouton Apple affiche désormais un message explicite au lieu de `(null)`.

---

## 6. Structure du projet

```
StudyTrack/                     # cible application
├── StudyTrackApp.swift          # point d'entrée (+ AppRuntime pour Siri)
├── App/
│   ├── AppContainer.swift       # injection SwiftData + services
│   ├── AppRouter.swift          # onglet actif, demandes de chrono, liens profonds
│   ├── AppRuntime.swift
│   ├── SettingsStore.swift      # réglages persistés
│   ├── RootTabView.swift        # onglets + garde d'onboarding + publication widget
│   └── Theme.swift
├── Models/                      # 13 entités SwiftData, énumérations,
│                                # catalogue de sections EPFL, données d'exemple
├── Domain/                      # ProgressEngine, WorkloadEngine, GamificationEngine,
│                                # DailyPlanner, DateUtils, FocusTimerState, SessionStats
│                                # (logique pure testée)
├── Services/                    # ICS, import JSON/CSV, EventKit, tâches (5 fournisseurs),
│                                # Supabase, notifications, App Intents, widget, export
└── Views/                       # Onboarding, Home, Courses, Focus, Groups, Agenda,
                                 # Stats, Tasks, Components (design system)

Shared/                          # compilé dans les deux cibles
├── WidgetBridge.swift           # contrat app ↔ widget (instantané, App Group)
└── ColorContrast.swift          # solveur de contraste WCAG (couleurs accessibles)

StudyTrackWidgets/               # cible d'extension WidgetKit
└── StudyTrackWidgets.swift      # timeline, widgets petit/moyen/grand
```

---

## 7. Limites connues

- L'interface a été **rendue et relue** dans le simulateur sur iPhone 17 et iPad Pro
  13″ (voir §1), mais **aucun test sur appareil réel** n'a été fait : posture,
  gestes et performance demandent du matériel. Le Mode sombre et les grandes tailles
  de Dynamic Type restent à contrôler de la même façon.
- Aucun test automatisé d'interface : la couverture reste `validate.sh` (domaine).
- Le catalogue de sections EPFL est indicatif (28 entrées) ; il est modifiable.
- Moodle : volontairement absent, faute d'accès API étudiant.
- Things 3 est en écriture seule (pas d'API de lecture) — signalé dans l'interface.
- **Ni widgets Control Center / StandBy, ni extension de partage** : ces chantiers demandent une nouvelle cible Xcode et une intervention dans le portail Apple Developer. La Live Activity du chrono, elle, est fournie dans la cible widget.
- L'icône d'app n'est pas fournie ; le widget d'écran d'accueil, lui, est fourni.
- La synchronisation Supabase est « best effort » : hors ligne, les groupes restent locaux.
