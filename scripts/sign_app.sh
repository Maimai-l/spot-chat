#!/usr/bin/env bash
# Signs the release app with the owner's own certificate, "Spot Chat Signing", instead of ad hoc. macOS
# remembers what the user allowed, Keychain items and Accessibility access, by the app's designated
# requirement; ad hoc that is the build's own hash, so every update lost it. With one certificate it is the
# certificate, the same for every build. The certificate isn't Apple's, so Gatekeeper treats the app as before.
#
# Usage: sign_app.sh <SpotChat.app>, with the certificate as base64 .p12 in MACOS_SIGNING_P12 and its password in
# MACOS_SIGNING_PASSWORD. Without them the app stays signed ad hoc.
set -euo pipefail
app="$1"
if [ -z "${MACOS_SIGNING_P12:-}" ]; then
  echo "::warning::No MACOS_SIGNING_P12 secret, so this alpha stays signed ad hoc"
  exit 0
fi

# A keychain of its own for this run, with a random password.
work="${RUNNER_TEMP:-$(mktemp -d)}"
keychain="$work/signing.keychain-db"
password="$(uuidgen)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$MACOS_SIGNING_P12" | base64 --decode > "$work/signing.p12"
security import "$work/signing.p12" -k "$keychain" -P "$MACOS_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$work/signing.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

# A self-signed certificate isn't trusted until this machine trusts it for code signing.
security find-certificate -c "Spot Chat Signing" -p "$keychain" > "$work/signing.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$work/signing.pem"
identity="$(security find-identity -v -p codesigning "$keychain" | awk '/"Spot Chat Signing"/ { print $2; exit }')"
if [ -z "$identity" ]; then
  echo "No valid \"Spot Chat Signing\" identity in the certificate:"
  security find-identity -p codesigning "$keychain"
  exit 1
fi

sign() {
  codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$@"
}
# Inside out, so each signature covers what is signed inside it: Sparkle's helpers, Sparkle, the reply
# writer, then the app, each keeping the entitlements Xcode gave it.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for service in "$sparkle"/Versions/B/XPCServices/*.xpc; do
  [ -e "$service" ] && sign --preserve-metadata=identifier,entitlements,flags "$service"
done
for helper in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
  [ -e "$helper" ] && sign --preserve-metadata=identifier,entitlements,flags "$helper"
done
sign --preserve-metadata=identifier,entitlements,flags "$sparkle"
sign --preserve-metadata=identifier,entitlements,flags "$app/Contents/MacOS/SpotChatWriter"
sign --preserve-metadata=identifier,entitlements,flags "$app"

# Not --strict: it turns down the symbolic links in the bundled dsh runtime, which macOS accepts.
codesign --verify --deep "$app"
echo "Signed with \"Spot Chat Signing\"; the designated requirement every build now shares:"
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /  /p'
