#!/bin/bash
# Import an existing identity; trust only this certificate for user-domain code signing.
set +x
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
temp_root=$(cd "${RUNNER_TEMP:-${TMPDIR:-/private/tmp}}" && pwd -P)

cleanup() {
  local dir=${WEFT_SIGNING_DIR:-}
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || die 'Missing or invalid WEFT_SIGNING_DIR.'
  [[ "$(cd "$dir/.." && pwd -P)" == "$temp_root" ]] || die 'Cleanup must stay directly inside the temporary root.'
  [[ "${dir##*/}" == weft-ci-signing.* && -f "$dir/.weft-ci-signing" ]] || die 'Refusing to clean an unowned directory.'
  local keychain="$dir/signing.keychain-db"
  if [[ -f "$dir/.trust-requested" ]]; then
    [[ -s "$dir/certificate.pem" && ! -L "$dir/certificate.pem" ]] || die 'Missing certificate needed to remove temporary trust.'
    security remove-trusted-cert "$dir/certificate.pem" || return 1
    rm -f -- "$dir/.trust-requested"
  fi
  if [[ -e "$keychain" ]]; then
    security delete-keychain "$keychain"
  fi
  rm -rf -- "$dir"
}

case "${1:-import}" in
  cleanup) cleanup; exit 0 ;;
  import) ;;
  *) die 'Usage: bash scripts/ci-import-signing.sh [import|cleanup]' ;;
esac

# CI must never silently fall back to local files or ad-hoc signing.
if [[ "${GITHUB_ACTIONS:-}" == true || -n "${MACOS_SIGNING_P12:-}${MACOS_SIGNING_PASSWORD:-}${MACOS_SIGNING_IDENTITY:-}" ]]; then
  [[ -n "${MACOS_SIGNING_P12:-}" && -n "${MACOS_SIGNING_PASSWORD:-}" && -n "${MACOS_SIGNING_IDENTITY:-}" ]] || die 'All three MACOS_SIGNING_* secrets are required.'
  source_mode=secrets
  identity=$MACOS_SIGNING_IDENTITY
else
  source_mode=local
  signing_root=${SIGNING_ROOT:-$HOME/.sign_keys_macos_app}
  for name in signing.p12 p12-password identity.sha1; do
    [[ -s "$signing_root/$name" ]] || die "Missing signing bootstrap file: $name"
  done
  identity=$(< "$signing_root/identity.sha1")
fi
[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || die 'Signing identity must be a 40-character certificate SHA1.'
identity=$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')

WEFT_SIGNING_DIR=$(mktemp -d "$temp_root/weft-ci-signing.XXXXXX")
export WEFT_SIGNING_DIR
touch "$WEFT_SIGNING_DIR/.weft-ci-signing"
trap 'status=$?; if (( status != 0 )); then cleanup || true; fi; exit "$status"' EXIT
keychain="$WEFT_SIGNING_DIR/signing.keychain-db"

# Publish the path before importing so the workflow always() step can recover it.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'WEFT_SIGNING_DIR=%s\nWEFT_SIGNING_KEYCHAIN=%s\nWEFT_SIGNING_IDENTITY=%s\n' \
    "$WEFT_SIGNING_DIR" "$keychain" "$identity" >> "$GITHUB_ENV"
fi
if [[ "$source_mode" == secrets ]]; then
  printf '%s' "$MACOS_SIGNING_P12" | /usr/bin/base64 --decode > "$WEFT_SIGNING_DIR/signing.p12"
  printf '%s' "$MACOS_SIGNING_PASSWORD" > "$WEFT_SIGNING_DIR/p12-password"
else
  cp "$signing_root/signing.p12" "$WEFT_SIGNING_DIR/signing.p12"
  cp "$signing_root/p12-password" "$WEFT_SIGNING_DIR/p12-password"
fi
chmod 600 "$WEFT_SIGNING_DIR/signing.p12" "$WEFT_SIGNING_DIR/p12-password"
openssl rand -hex 32 > "$WEFT_SIGNING_DIR/keychain-password"
chmod 600 "$WEFT_SIGNING_DIR/keychain-password"
p12_password=$(< "$WEFT_SIGNING_DIR/p12-password")
keychain_password=$(< "$WEFT_SIGNING_DIR/keychain-password")
[[ -n "$p12_password" ]] || die 'An encrypted PKCS12 password is required.'
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
python3 - "$keychain" <<'PY'
import shlex, subprocess, sys
paths = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
if sys.argv[1] not in paths:
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *paths, sys.argv[1]], check=True)
PY
security import "$WEFT_SIGNING_DIR/signing.p12" -k "$keychain" -f pkcs12 \
  -P "$p12_password" -x -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S 'apple-tool:,apple:,codesign:' -s -t private \
  -k "$keychain_password" "$keychain" > /dev/null
/usr/bin/openssl pkcs12 -in "$WEFT_SIGNING_DIR/signing.p12" -clcerts -nokeys \
  -passin "file:$WEFT_SIGNING_DIR/p12-password" -out "$WEFT_SIGNING_DIR/certificate.pem"
certificate_identity=$(/usr/bin/openssl x509 -in "$WEFT_SIGNING_DIR/certificate.pem" -noout -fingerprint -sha1)
certificate_identity=${certificate_identity#*=}
certificate_identity=${certificate_identity//:/}
[[ "$certificate_identity" == "$identity" ]] || die 'PKCS12 leaf certificate does not match MACOS_SIGNING_IDENTITY.'
# Local bootstrap owns persistent user trust. Only CI adds/removes temporary trust.
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  # Never use the system domain (-d). Mark before a potentially partial failure.
  touch "$WEFT_SIGNING_DIR/.trust-requested"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$WEFT_SIGNING_DIR/certificate.pem"
fi
unset p12_password keychain_password MACOS_SIGNING_P12 MACOS_SIGNING_PASSWORD
rm -f -- "$WEFT_SIGNING_DIR/signing.p12" "$WEFT_SIGNING_DIR/p12-password" "$WEFT_SIGNING_DIR/keychain-password"

# Do not infer usability from find-identity -v counts. Test the actual key and SHA1.
cp /usr/bin/true "$WEFT_SIGNING_DIR/signing-probe"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none \
  --identifier me.weishu.Weft "$WEFT_SIGNING_DIR/signing-probe"
codesign --verify --strict -R "=identifier \"me.weishu.Weft\" and certificate leaf = H\"$identity\"" \
  "$WEFT_SIGNING_DIR/signing-probe"
rm -f -- "$WEFT_SIGNING_DIR/signing-probe"
printf 'export WEFT_SIGNING_DIR=%q\nexport WEFT_SIGNING_KEYCHAIN=%q\nexport WEFT_SIGNING_IDENTITY=%q\n' \
  "$WEFT_SIGNING_DIR" "$keychain" "$identity" > "$WEFT_SIGNING_DIR/signing.env"
printf 'Signing identity verified. Local environment: %s/signing.env\n' "$WEFT_SIGNING_DIR"
