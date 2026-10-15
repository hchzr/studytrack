#!/usr/bin/env bash
#
# Validation exécutable des modèles SwiftData et des moteurs métier.
#
# Compile StudyTrack/Models + StudyTrack/Domain (+ le thème) dans un binaire macOS
# et vérifie : schéma SwiftData, relations inverses, moteurs de progression, de
# charge EPFL et de gamification, ainsi que les entités sociales / tâches.
#
#   ./validate.sh           # contrôles de correction (967 assertions)
#   ./validate.sh --bench   # + repères de performance sur un semestre simulé
#
# Utile car l'app iOS complète ne peut pas être exécutée sans simulateur installé.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Scratch dir OUTSIDE the project tree. Never write Swift sources into the repo:
# Xcode's synchronized folder groups scan the project, and a second file named
# like a real source file produces "Multiple commands produce <file>.stringsdata".
WORK="$(mktemp -d "${TMPDIR:-/tmp}/studytrack-validation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources"

cp "$ROOT"/StudyTrack/Models/*.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Domain/*.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/App/Theme.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/App/SupabaseConfig.swift "$WORK/Sources/"
cp "$ROOT"/Shared/ColorContrast.swift "$WORK/Sources/"
# La logique de temps de la Live Activity est pure (pas d'ActivityKit) : elle se
# teste donc ici, ce qui aurait attrapé le compteur qui repartait de zéro.
cp "$ROOT"/Shared/ActivityTimerState.swift "$WORK/Sources/"
# Même raison pour le jour d'examen : quand l'activité s'ouvre et quand elle se
# ferme sont des décisions pures, et ce sont les seules qui puissent se tromper.
cp "$ROOT"/Shared/ExamActivityState.swift "$WORK/Sources/"
cp "$ROOT"/Shared/WidgetBridge.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/DataExporter.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/CalendarService.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/TimetableImportService.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/TimetableImport.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/CourseImporter.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/SeriesPDFParser.swift "$WORK/Sources/"
cp "$ROOT"/StudyTrack/Services/PDFLayoutExtractor.swift "$WORK/Sources/"
cp "$ROOT"/Validation/main.swift "$WORK/Sources/"
cp "$ROOT"/Validation/PDFFixtures.swift "$WORK/Sources/"
cp "$ROOT"/Validation/BotafogoFixtures.swift "$WORK/Sources/"

# Garde-fou : tout type annoté `@Model` doit figurer dans le schéma versionné.
#
# C'est l'oubli qui avait laissé `GroupItemCompletion` hors du conteneur — la
# relation le ramassait par chance, mais rien ne le garantissait. On lit donc les
# sources et on **génère** la liste, pour que le test compare le code au schéma.
MODELS=$(awk '/^@Model/ { while (getline > 0 && $0 !~ /class/) ; if (match($0, /class [A-Za-z0-9_]+/)) print substr($0, RSTART + 6, RLENGTH - 6) }' \
  "$ROOT"/StudyTrack/Models/*.swift | sort -u)
{
  echo "// Généré par validate.sh à partir des sources : ne pas éditer."
  echo "let declaredModelNames: [String] = ["
  for model in $MODELS; do echo "    \"$model\","; done
  echo "]"
} > "$WORK/Sources/GeneratedModels.swift"
echo "→ Modèles déclarés : $(echo "$MODELS" | wc -l | tr -d ' ')"

SDK="$(xcrun --show-sdk-path --sdk macosx)"

echo "→ Compilation de la validation…"
xcrun swiftc -disable-sandbox \
  -module-cache-path "$WORK/mc" \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -o "$WORK/validate" \
  "$WORK"/Sources/*.swift

echo "→ Exécution…"
"$WORK/validate" "$@"
