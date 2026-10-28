#!/bin/bash
# Build a distributable ad-hoc-signed Apple Silicon app from committed sources only.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root=$PWD
[[ -z $(git status --porcelain) ]] || { echo "Commit changes before packaging." >&2; exit 1; }
revision=$(git rev-parse HEAD)
stage=$(mktemp -d /private/tmp/weft-release.XXXXXX)
# Keep the staging directory for inspection; it contains public committed files only.
git archive HEAD | tar -x -C "$stage"
cd "$stage"
xcodegen generate --quiet
swift test --package-path Packages/WeftKit
xcodebuild -quiet -project Weft.xcodeproj -scheme Weft -configuration Release \
  -derivedDataPath "$stage/DerivedData" -destination 'generic/platform=macOS' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  WEFT_SOURCE_REVISION="$revision" DEBUG_INFORMATION_FORMAT=dwarf build
app="$stage/DerivedData/Build/Products/Release/Weft.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
embedded=$(/usr/libexec/PlistBuddy -c 'Print WeftSourceRevision' "$app/Contents/Info.plist")
[[ $embedded == "$revision" ]] || { echo 'Source revision mismatch' >&2; exit 1; }
# A clean archive excludes ignored credentials, database files, preferences and reports.
python3 - "$app" <<'SCAN'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
patterns=[rb'/Users/[^/\x00\s]+/', rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', rb'gh[pousr]_[A-Za-z0-9]{30,}', rb'sk-[A-Za-z0-9_-]{32,}']
for path in root.rglob('*'):
    if not path.is_file(): continue
    data=path.read_bytes()
    if any(re.search(p,data) for p in patterns):
        raise SystemExit('Sensitive-data scan failed for bundled file: '+str(path.relative_to(root)))
print('Application privacy scan passed.')
SCAN
out="$repo_root/build/release"
mkdir -p "$out"
zip="$out/Weft-$version-arm64.zip"
[[ ! -e $zip ]] || { echo "Artifact already exists: $zip" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
cd "$out"
shasum -a 256 "$(basename "$zip")" > SHA256SUMS.txt
echo "Packaged source revision $revision"
echo "Output: $zip"
