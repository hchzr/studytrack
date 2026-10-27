#!/usr/bin/env bash
#
# Distribuer StudyTrack (README §5, « Distribuer ») :
#
#   ./release.sh ios           # archive → export App Store Connect → envoi (TestFlight)
#   ./release.sh mac           # archive → Developer ID → notarisation → StudyTrack.dmg + latest.json
#   ./release.sh publish-mac   # l'image sur une release du site et de l'app, latest.json poussé
#
# Signature et envoi : le compte de Xcode (Réglages › Comptes), celui du
# titulaire — la signature « dans le nuage » (certificats Distribution et
# Developer ID gérés par Apple) lui est réservée ; une clé « App Manager » ne
# l'a pas (« Cloud signing permission error », constaté).
# Notarisation du Mac : la clé App Store Connect — ASC_KEY_ID et ASC_ISSUER_ID
# dans l'environnement, AuthKey_<ASC_KEY_ID>.p8 à la racine (ignoré par git).
# Monter CURRENT_PROJECT_VERSION avant chaque envoi : App Store Connect refuse
# un numéro déjà vu, et le Mac compare ce numéro pour annoncer une mise à jour.
#
# `-disable-sandbox` : voir build.sh (sans effet sur l'app).

set -euo pipefail
cd "$(dirname "$0")"

: "${ASC_KEY_ID:?ASC_KEY_ID manquant (Key ID de la clé App Store Connect)}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID manquant (Issuer ID de la clé)}"
KEY="$PWD/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$KEY" ] || { echo "Clé introuvable : $KEY" >&2; exit 1; }
AUTH=(-allowProvisioningUpdates)
NOTARY=(--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
TEAM=5GGDH5F3NG
OUT=build-release
SITE_RELEASES=hchzr/studytrack-site
mkdir -p "$OUT"

setting() {
  xcodebuild -project StudyTrack.xcodeproj -scheme "$1" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -v k="$2" '$1 == k { print $3; exit }'
}

export_options() { # méthode, destination
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>$1</string>
	<key>destination</key><string>$2</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
}

# Le certificat « Developer ID Application » de l'équipe (pour signer l'image).
# Une fonction plutôt qu'un `$( … )` sur deux lignes : le bash 3.2 de macOS
# s'y perd dans les guillemets.
developer_id() {
  security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM)" | head -1 | cut -d'"' -f2 || true
}

# La notarisation : `--wait` rend la main au verdict, qu'il faut lire.
notarize() {
  local log="$OUT/notary-$(basename "$1").log"
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait | tee "$log"
  grep -q "status: Accepted" "$log" || {
    echo "Notarisation refusée — détail : xcrun notarytool log <id> ${NOTARY[*]}" >&2
    exit 1
  }
}

case "${1:-}" in
ios)
  VERSION=$(setting StudyTrack MARKETING_VERSION); BUILD=$(setting StudyTrack CURRENT_PROJECT_VERSION)
  ARCHIVE="$OUT/StudyTrack-$VERSION-$BUILD.xcarchive"
  echo "→ iPhone $VERSION ($BUILD), Temps d'écran : $(setting StudyTrack STUDYTRACK_SCREEN_TIME)"
  xcodebuild archive -project StudyTrack.xcodeproj -scheme StudyTrack -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${AUTH[@]}" \
    OTHER_SWIFT_FLAGS="-disable-sandbox"
  export_options app-store-connect upload > "$OUT/ios-export.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ios-export.plist" \
    -exportPath "$OUT/ios" "${AUTH[@]}"
  echo "✅ Envoyée. App Store Connect la traite (~15 min) puis elle apparaît dans TestFlight."
  ;;
mac)
  VERSION=$(setting StudyTrackMac MARKETING_VERSION); BUILD=$(setting StudyTrackMac CURRENT_PROJECT_VERSION)
  ARCHIVE="$OUT/StudyTrackMac-$VERSION-$BUILD.xcarchive"
  echo "→ Mac $VERSION ($BUILD)"
  xcodebuild archive -project StudyTrack.xcodeproj -scheme StudyTrackMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" "${AUTH[@]}" \
    OTHER_SWIFT_FLAGS="-disable-sandbox"
  export_options developer-id export > "$OUT/mac-export.plist"
  rm -rf "$OUT/mac"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/mac-export.plist" \
    -exportPath "$OUT/mac" "${AUTH[@]}"
  APP="$OUT/mac/StudyTrack.app"
  # L'app d'abord (son ticket est agrafé : elle s'ouvre même hors ligne), puis l'image.
  ditto -c -k --keepParent "$APP" "$OUT/StudyTrack-app.zip"
  notarize "$OUT/StudyTrack-app.zip"
  xcrun stapler staple "$APP"
  STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/StudyTrack.app"
  ln -s /Applications "$STAGE/Applications"
  DMG="$OUT/StudyTrack.dmg"; rm -f "$DMG"
  hdiutil create -volname StudyTrack -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  # L'image n'est signée que si le certificat est dans le trousseau (avec la
  # signature dans le nuage, il n'y est pas) : macOS ouvre une image non signée,
  # et c'est l'app qu'elle contient, notarisée, que Gatekeeper vérifie.
  IDENTITY=$(developer_id)
  if [ -n "$IDENTITY" ]; then codesign --sign "$IDENTITY" --timestamp "$DMG"; fi
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  TAG="mac-$VERSION-$BUILD"
  cat > "$OUT/latest.json" <<EOF
{"version": "$VERSION", "build": $BUILD, "url": "https://github.com/$SITE_RELEASES/releases/download/$TAG/StudyTrack.dmg", "notes": "${NOTES:-}"}
EOF
  echo "✅ $DMG notarisée. Puis : ./release.sh publish-mac (SITE_REPO=<clone de studytrack-site>)"
  ;;
publish-mac)
  : "${SITE_REPO:?SITE_REPO manquant : le chemin vers un clone de studytrack-site}"
  VERSION=$(setting StudyTrackMac MARKETING_VERSION); BUILD=$(setting StudyTrackMac CURRENT_PROJECT_VERSION)
  TAG="mac-$VERSION-$BUILD"
  [ -f "$OUT/StudyTrack.dmg" ] && [ -f "$OUT/latest.json" ] || { echo "Lancer d'abord ./release.sh mac" >&2; exit 1; }
  gh release create "$TAG" "$OUT/StudyTrack.dmg" --repo "$SITE_RELEASES" \
    --title "StudyTrack pour Mac $VERSION ($BUILD)" --notes "${NOTES:-StudyTrack pour Mac $VERSION ($BUILD).}"
  mkdir -p "$SITE_REPO/mac"
  cp "$OUT/latest.json" "$SITE_REPO/mac/latest.json"
  git -C "$SITE_REPO" add mac/latest.json
  git -C "$SITE_REPO" commit -m "Mac $VERSION ($BUILD)"
  git -C "$SITE_REPO" push
  # La même release dans le dépôt de l'app (privé : le lien de latest.json reste
  # celui du site, public). L'étiquette va sur HEAD, le commit construit par
  # `./release.sh mac`, et part seule : main n'a pas à être poussée pour autant.
  git tag -a "$TAG" -m "StudyTrack $VERSION ($BUILD)"
  git push origin "refs/tags/$TAG"
  gh release create "$TAG" "$OUT/StudyTrack.dmg" --verify-tag \
    --title "StudyTrack $VERSION ($BUILD)" --notes "${NOTES:-StudyTrack pour Mac $VERSION ($BUILD).}"
  echo "✅ Publiée : https://github.com/$SITE_RELEASES/releases/tag/$TAG"
  ;;
*)
  sed -n '3,7p' "$0"; exit 2 ;;
esac
