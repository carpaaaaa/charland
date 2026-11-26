#!/bin/zsh
# Compila Charland. La cartella di build sta fuori dal Desktop: i permessi del Desktop
# bloccano i processi di Xcode, e codesign rifiuta i metadati del Finder.
#
#   Scripts/build.sh            build di sviluppo
#   Scripts/build.sh release    build ottimizzata
#   Scripts/build.sh install    build ottimizzata e copia in /Applications (sostituisce /Applications/Charland.app!)
#   Scripts/build.sh official   build ufficiale: ottimizzata, con gli aggiornamenti automatici accesi
#                               (CHARLAND_OFFICIAL). Serve solo a chi pubblica le versioni: va firmata Developer ID e notarizzata.
set -euo pipefail
cd "$(dirname "$0")/.."

config="Debug"
extra=()
[[ "${1:-}" == "release" || "${1:-}" == "install" || "${1:-}" == "official" ]] && config="Release"
[[ "${1:-}" == "official" ]] && extra=(SWIFT_ACTIVE_COMPILATION_CONDITIONS=CHARLAND_OFFICIAL)
build="${CHARLAND_BUILD_DIR:-$HOME/Library/Caches/charland-build}"

Scripts/genera-identita.sh > /dev/null
xcodegen generate --quiet

log="$build/ultima-build.log"
mkdir -p "$build"
if ! xcodebuild -project Charland.xcodeproj -scheme Charland -configuration "$config" \
    -derivedDataPath "$build" -destination 'platform=macOS,arch=arm64' "${extra[@]}" build > "$log" 2>&1; then
  grep -E "error:|warning: unre|\*\* BUILD FAILED" "$log" | sed -E 's|/Users/[^ ]*/Charland/||' | sort -u | head -40
  echo "Build fallita. Registro completo: $log"
  exit 1
fi

app="$build/Build/Products/$config/Charland.app"
echo "$app"

if [[ "${1:-}" == "install" ]]; then
  dest="/Applications/Charland.app"
  pkill -x Charland 2>/dev/null || true
  rm -rf "$dest"
  ditto "$app" "$dest"
  # ditto conserva le date: senza questi touch il Mac mostra l'icona vecchia.
  touch "$dest" "$dest/Contents" "$dest/Contents/Info.plist" "$dest/Contents/Resources" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
  # Togliendo il pacchetto launchd perde l'aiutante del coperchio chiuso, anche se Impostazioni di Sistema lo dà per
  # approvato: lo rimette a posto subito (Charland lo farebbe comunque al prossimo avvio).
  "$dest/Contents/MacOS/Charland" --helper-repair 2>/dev/null | grep -E "registrato|risponde" || true
  echo "installata in $dest"
fi
