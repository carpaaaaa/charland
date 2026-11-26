#!/bin/zsh
# Scarica le librerie di terze parti che non stanno nel repository.
# Ognuna viene dalla sua fonte ufficiale ed è controllata con l'impronta SHA-256.
#
#   sherpa-onnx (Apache-2.0): il motore che fa girare Parakeet e Orukeet.
#   Versione nativa per Apple silicon: quella universale è circa 3 volte più lenta.
#   Da qui vengono ONNX Runtime e l'intestazione C; la libreria di sherpa-onnx viene poi ricompilata
#   con la modifica di Charland (Scripts/compila-sherpa.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

version="v2.0.1"
name="sherpa-onnx-$version-osx-arm64-shared-no-tts-lib"
url="https://github.com/k2-fsa/sherpa-onnx/releases/download/$version/$name.tar.bz2"
sha="${SHERPA_SHA256:-ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3}"
dest="Vendor/sherpa-onnx"

if [[ -f "$dest/lib/libsherpa-onnx-c-api.dylib" && -f "$dest/VERSIONE" && "$(cat "$dest/VERSIONE")" == "$version" ]]; then
  echo "sherpa-onnx $version già presente"
  # La libreria di Charland ha una piccola modifica (vocabolario della dettatura): si compila qui.
  Scripts/compila-sherpa.sh
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "scarico $url"
curl -fL --retry 3 -o "$tmp/archivio.tar.bz2" "$url"
found="$(shasum -a 256 "$tmp/archivio.tar.bz2" | awk '{print $1}')"
echo "impronta: $found"
if [[ -n "$sha" && "$sha" != "$found" ]]; then
  echo "impronta diversa da quella attesa ($sha): mi fermo" >&2
  exit 1
fi
mkdir -p "$tmp/estratto"
tar -xjf "$tmp/archivio.tar.bz2" -C "$tmp/estratto"
root="$(find "$tmp/estratto" -maxdepth 1 -mindepth 1 -type d | head -1)"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$root/lib" "$dest/lib"
# L'archivio delle librerie non ha le intestazioni: l'intestazione C viene dal repository, alla stessa versione.
mkdir -p "$dest/include/sherpa-onnx/c-api"
curl -fsL -o "$dest/include/sherpa-onnx/c-api/c-api.h" \
  "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$version/sherpa-onnx/c-api/c-api.h"
impronta_h="5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f"
[[ "$(shasum -a 256 "$dest/include/sherpa-onnx/c-api/c-api.h" | awk '{print $1}')" == "$impronta_h" ]] \
  || { echo "c-api.h ha un'impronta diversa da quella attesa: mi fermo" >&2; exit 1; }
cat > "$dest/include/module.modulemap" <<'MAP'
module SherpaOnnx {
    header "sherpa-onnx/c-api/c-api.h"
    link "sherpa-onnx-c-api"
    export *
}
MAP
echo "$version" > "$dest/VERSIONE"
echo "$found" > "$dest/SHA256"
# Le librerie scaricate portano l'attributo di quarantena: toglierlo evita blocchi al caricamento.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
rm -f "$dest/MODIFICA"
# Sopra la libreria ufficiale va quella con la modifica di Charland (vocabolario della dettatura).
Scripts/compila-sherpa.sh
ls -la "$dest/lib"
