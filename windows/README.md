# Polymestre pour Windows

Le portage de l'app Mac (PolymestreMac + StudyKit + Models + Domain) sur Windows :
**Tauri 2** (shell Rust) + **React 19 / TypeScript** (webview), base locale **SQLite**
(tauri-plugin-sql) et **synchronisation Supabase** (les apps Apple la rejoignent).

Le tout de suite, premier réflexe : lire `windows/HANDOFF.md` (où on en est),
`PORTING.md` (règles de fidélité Swift → TS), `UI.md` (contrat des écrans).

## Lancer

```bash
npm install
npm test               # Vitest — le portage des ~2 400 assertions de Validation/main.swift
npx tsc --noEmit -p .  # type-check
npm run dev            # dans le navigateur : source mémoire (données d'essai)
npm run tauri dev      # l'app : SQLite réelle + shell Rust
npm run tauri build    # .msi / .exe (CI sur windows-latest : .github/workflows/windows.yml)
```

## La source des données (au lancement)

- **Dans l'app Tauri** : la base SQLite locale (`polymestre.db` dans le dossier de
  l'app), lue et écrite par `Repository` (src/data/repository.ts) au-dessus du
  moteur de synchronisation.
- **Dans le navigateur** (`npm run dev`) : source en mémoire amorcée par
  `SeedData` — le plugin n'existe pas hors du shell.
- Paramètres d'adresse pour un essai : `?source=memory` (données d'essai sans
  créer de base) et `?source=sqlite&seed=1` (amorce la base du premier
  lancement). Voir `src/data/appSource.ts`.

## Le code

```
src-tauri/   shell Rust : fenêtre, plugins (sql, opener) ; le reste viendra ici
src/
  domain/    portage 1:1 de Polymestre/Domain (pur, sans UI, testé)
  models/    les 20 modèles de SchemaV1 + store + SeedData
  data/      bridge base ↔ graphe d'objets : hydrate, Repository, sources
  sync/      base locale (SQLite) + moteur d'envoi/lecture + transport Supabase
  services/  clients (Supabase, parseurs PDF…)
  ui/        écrans React (tokens Carnet dans tokens.css, kit dans kit.tsx)
tests/       Vitest — un `it` par check de Validation/main.swift
```
