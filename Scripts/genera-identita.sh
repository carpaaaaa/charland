#!/bin/zsh
# Scrive Identity.generated.swift a partire da Config/Identita.xcconfig,
# così nome, identificativo, comando e indirizzo stanno in un punto solo.
set -euo pipefail
cd "$(dirname "$0")/.."
conf="Config/Identita.xcconfig"
out="Packages/CharlandCore/Sources/CharlandCore/Identity.generated.swift"

local_conf="Config/Local.xcconfig"
# Config/Local.xcconfig (se c'è) vince su Identita.xcconfig.
valore() { grep -h -E "^$1[[:space:]]*=" "$local_conf" "$conf" 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s|[[:space:]]*//.*$||; s/[[:space:]]*$//'; }

cat > "$out" <<EOF
// Generato da Scripts/genera-identita.sh. Non modificare: cambia Config/Identita.xcconfig.

/// L'identità dell'app, in un punto solo.
public enum Identity {
    public static let name = "$(valore CHARLAND_NAME)"
    public static let bundleID = "$(valore CHARLAND_BUNDLE_ID)"
    public static let cli = "$(valore CHARLAND_CLI)"
    public static let urlScheme = "$(valore CHARLAND_URL_SCHEME)"
    public static let version = "$(valore CHARLAND_VERSION)"
    public static let site = "$(valore CHARLAND_SITE)"
    /// Servizio XPC del motore vocale.
    public static let voiceServiceID = "$(valore CHARLAND_BUNDLE_ID).voce"
    /// Cartella dei dati: ~/Library/Application Support/<name>.
    public static let supportFolder = "$(valore CHARLAND_NAME)"
}
EOF
echo "scritto $out"
