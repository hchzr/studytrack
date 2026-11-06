#!/usr/bin/env bash
#
# Build Polymestre pour le simulateur iOS.
#
#   ./build.sh              # Debug
#   CONFIGURATION=Release ./build.sh
#
# Note sur `-disable-sandbox` :
# Le compilateur Swift encapsule le « swift-plugin-server » (qui exécute les macros
# SwiftData / Observation / SwiftUI) dans son propre sandbox-exec. Dans un
# environnement déjà sandboxé (agent IA, CI restreinte), ce sandbox imbriqué échoue
# avec « sandbox_apply: Operation not permitted », et la compilation produit
# « swift-plugin-server produced malformed response ». Désactiver ce sandbox
# interne rend la compilation possible ; sans effet sur le comportement de l'app.
# Dans Xcode normal, ce drapeau n'est pas nécessaire.
#
# `-DNO_CLOUDKIT` : la build n'est pas signée, donc sans le droit iCloud — et
# CloudKit arrête l'app au lieu de lever une erreur. La base reste locale.

set -euo pipefail

CONFIGURATION="${CONFIGURATION:-Debug}"

xcodebuild \
  -project Polymestre.xcodeproj \
  -scheme Polymestre \
  -sdk iphonesimulator \
  -configuration "$CONFIGURATION" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-disable-sandbox -DNO_CLOUDKIT" \
  build
