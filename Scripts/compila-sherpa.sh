#!/bin/zsh
# Compila sherpa-onnx con la modifica di Charland e mette la libreria in Vendor/sherpa-onnx/lib.
#
# La modifica (Scripts/sherpa-onnx-charland.patch, una cinquantina di righe) dà a un solo modello in memoria
# due modi di leggere la stessa analisi dell'audio: quello sicuro di sempre (greedy) e la ricerca a fascio che
# favorisce le parole del vocabolario. Senza, servirebbero due modelli caricati: quasi 2 GB invece di 1.
# La libreria si riconosce dalla versione: «2.0.1+charland.1».
#
# Serve cmake. Se non c'è, lo script lo mette in un ambiente Python suo, senza toccare il sistema.
# ONNX Runtime resta quello ufficiale già scaricato da Scripts/scarica-dipendenze.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

version="v2.0.1"
mark="$version+charland.1"
dest="Vendor/sherpa-onnx"
patch="$PWD/Scripts/sherpa-onnx-charland.patch"
work="${CHARLAND_SHERPA_BUILD:-$HOME/Library/Caches/charland-sherpa-build}"

if [[ ! -f "$dest/lib/libonnxruntime.dylib" ]]; then
  echo "manca $dest: prima Scripts/scarica-dipendenze.sh" >&2
  exit 1
fi
if [[ -f "$dest/MODIFICA" && "$(cat "$dest/MODIFICA")" == "$mark" && "${1:-}" != "di-nuovo" ]]; then
  echo "sherpa-onnx $mark già presente"
  exit 0
fi

mkdir -p "$work"
if ! command -v cmake > /dev/null || ! command -v ninja > /dev/null; then
  [[ -x "$work/venv/bin/cmake" ]] || { python3 -m venv "$work/venv" && "$work/venv/bin/pip" install --quiet cmake ninja; }
  export PATH="$work/venv/bin:$PATH"
fi

src="$work/sherpa-onnx"
if [[ ! -d "$src/.git" ]]; then
  git clone --quiet --depth 1 --branch "$version" https://github.com/k2-fsa/sherpa-onnx.git "$src"
  # Il tag deve puntare al commit atteso: un tag spostato a monte non entra nella build senza che ce ne accorgiamo.
  atteso="af2d8d81dbfa61c4cea4c568da78f3982edca005"
  [[ "$(git -C "$src" rev-parse HEAD)" == "$atteso" ]] || { echo "sherpa-onnx $version non è il commit atteso ($atteso): mi fermo" >&2; exit 1; }
fi
git -C "$src" checkout --quiet -- .
git -C "$src" apply "$patch"

build="$src/build-charland"
mkdir -p "$build"
cmake -S "$src" -B "$build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF > "$build/configura.log" 2>&1
ninja -C "$build" sherpa-onnx-c-api > "$build/compila.log" 2>&1

cp "$build/lib/libsherpa-onnx-c-api.dylib" "$dest/lib/libsherpa-onnx-c-api.dylib"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
echo "$mark" > "$dest/MODIFICA"
shasum -a 256 "$dest/lib/libsherpa-onnx-c-api.dylib" | awk '{print $1}' > "$dest/SHA256-MODIFICA"
echo "sherpa-onnx $mark in $dest/lib"
