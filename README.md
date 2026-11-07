# Polymestre

Polymestre rassemble tes cours de EPFL

L'app connaît la forme d'un cours à l'EPFL : les vidéos, les séries et leurs sous-exercices, les corrections, les évaluations. Elle récupère ce qu'il faut depuis Moodle, Botafogo, Ed et IS-Academia, puis garde le compte de ce que tu as vraiment fait et du temps que ça t'a pris. Il y a aussi un mode étude avec chrono, un tuteur IA qui donne des indices plutôt que la réponse, et des groupes pour travailler à plusieurs.

Elle est gratuite et n'a aucun lien officiel avec l'EPFL.

## Installer

- **iPhone (iOS 17+)** : [bêta TestFlight](https://testflight.apple.com/join/ZVnuFAbM)
- **Mac (macOS 14+) et Windows** : [polymestre.ch](https://polymestre.ch) ou [releases](https://github.com/hczr-dev/polymestre/releases)

## Compiler

L'app Apple s'ouvre dans Xcode avec `Polymestre.xcodeproj`. En ligne de commande :

```bash
./build.sh      # l'app iPhone pour le simulateur
```

Pour Windows (Tauri et React) :

```bash
cd windows
npm install
npm test
npm run tauri dev
```

La configuration des services (Supabase, MCP, signature, distribution) est dans [`docs/configuration.md`](docs/configuration.md).

## Le dépôt

- `Polymestre/` : l'app iPhone et iPad, avec les modèles et la logique communs
- `PolymestreMac/` : l'app Mac
- `StudyKit/` : le code partagé entre l'iPhone et le Mac
- `windows/` : l'app Windows
- `supabase/` : la base, les fonctions et le serveur MCP
- `relay/` : le relais du chrono partagé

## Licence

[MIT](LICENSE)
