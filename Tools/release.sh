#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Tools/release.sh <version>, e.g. 1.0.1}"
REPO="Extrik808/LidShot"
TAP_REPO="Extrik808/homebrew-tap"
TAP_DIR="${TAP_DIR:-$HOME/IdeaProjects/homebrew-tap}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean; commit first." >&2
    exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
    GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | awk -F= '/^password=/{print $2}')
    export GH_TOKEN
fi

BUILD=$(git rev-list --count HEAD)
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
git commit -qam "Release $VERSION"
git tag "v$VERSION"

./build.sh
mkdir -p dist
ZIP="dist/LidShot-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/LidShot.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "LidShot $VERSION" --notes "Install or update: \`brew install --cask extrik808/tap/lidshot\` / \`brew upgrade --cask lidshot\`"

if [[ ! -d "$TAP_DIR/.git" ]]; then
    git clone -q "https://github.com/$TAP_REPO.git" "$TAP_DIR"
fi
git -C "$TAP_DIR" pull -q --ff-only
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" Tools/lidshot.rb.template > "$TAP_DIR/Casks/lidshot.rb"
git -C "$TAP_DIR" add Casks/lidshot.rb
git -C "$TAP_DIR" commit -qm "lidshot $VERSION"
git -C "$TAP_DIR" push -q

echo "Released $VERSION ($SHA)"
