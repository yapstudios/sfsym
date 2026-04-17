#!/bin/bash
# Ship a new sfsym release end to end.
#
#   Scripts/release.sh 0.2.1
#
# What this does, top to bottom:
#   1. Bumps sfsymVersion in Sources/sfsym/CLI.swift.
#   2. Rebuilds the release binary locally and confirms --version reports right.
#   3. Regenerates demo.svg (typing animation).
#   4. Stages a clean tree (no .build, no web/all/) into /tmp.
#   5. Force-pushes a SINGLE commit to github.com/yapstudios/sfsym main,
#      blowing away the previous history. Every release = one commit.
#   6. Deletes + recreates the v<version> tag and GitHub release.
#   7. Computes sha256 of the release tarball.
#   8. Updates Formula/sfsym.rb in github.com/yapstudios/homebrew-tap to point
#      at the new tarball + sha256 + version.
#   9. Pushes the tap.
#
# No PR workflow, no intermediate branches. sfsym is a single-maintainer
# tool; this script assumes that.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: Scripts/release.sh <version>        (e.g. 0.2.1)" >&2
    exit 64
fi

VERSION="$1"
TAG="v${VERSION}"
REPO="yapstudios/sfsym"
TAP="yapstudios/homebrew-tap"
FORMULA_PATH="Formula/sfsym.rb"

# Let us run from the repo root regardless of where we're invoked.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd -P)"

# --- 1. bump version ------------------------------------------------------
echo "==> bumping sfsymVersion to ${VERSION}"
/usr/bin/sed -i '' \
    -E "s/let sfsymVersion = \"[^\"]+\"/let sfsymVersion = \"${VERSION}\"/" \
    Sources/sfsym/CLI.swift
/usr/bin/grep 'let sfsymVersion' Sources/sfsym/CLI.swift

# --- 2. rebuild + install locally ----------------------------------------
echo "==> building release binary"
swift build -c release > /dev/null
BIN_VERSION="$(.build/release/sfsym --version | /usr/bin/awk '{print $2}')"
if [[ "$BIN_VERSION" != "$VERSION" ]]; then
    echo "--version reports ${BIN_VERSION}, expected ${VERSION}" >&2
    exit 2
fi
if [[ -w "${HOME}/.local/bin" ]]; then
    /bin/cp -f .build/release/sfsym "${HOME}/.local/bin/sfsym"
fi

# --- 3. regenerate demo.svg ----------------------------------------------
if [[ -f build-demo-svg.py ]]; then
    echo "==> rebuilding demo.svg"
    /usr/bin/python3 build-demo-svg.py > /dev/null
fi

# --- 4. stage a clean tree -----------------------------------------------
STAGE="$(/usr/bin/mktemp -d /tmp/sfsym-release.XXXXXX)"
trap '/bin/rm -rf "$STAGE"' EXIT
echo "==> staging publish tree at ${STAGE}"

/bin/cp -R Sources Scripts "$STAGE/"
mkdir -p "$STAGE/web"
/bin/cp web/build.sh web/build-all.sh web/build-all.py web/gen.py "$STAGE/web/"
/bin/cp Package.swift README.md LICENSE .gitignore "$STAGE/"
[[ -f build-demo-svg.py ]] && /bin/cp build-demo-svg.py "$STAGE/"
[[ -f demo.svg ]] && /bin/cp demo.svg "$STAGE/"
[[ -f architecture.svg ]] && /bin/cp architecture.svg "$STAGE/"
# Drop stray macOS metadata.
/usr/bin/find "$STAGE" -name '.DS_Store' -delete

# Sanity: the staged tree builds on its own.
echo "==> verifying staged tree builds"
(cd "$STAGE" && swift build -c release > /dev/null)

# --- 5. force-push single-commit history ---------------------------------
echo "==> force-pushing single-commit history to ${REPO}"
cd "$STAGE"
git init -q -b main
git add .
git -c user.name="$(git --git-dir="$ROOT/../.git" config user.name)" \
    -c user.email="$(git --git-dir="$ROOT/../.git" config user.email)" \
    commit -q -m "sfsym ${VERSION}

See README.md."
git remote add origin "https://github.com/${REPO}.git"
git push --force origin main > /dev/null 2>&1

# --- 6. tag + release ----------------------------------------------------
echo "==> resetting tag and release for ${TAG}"
# Delete the remote tag if it exists (ignore error if it doesn't).
git push origin ":refs/tags/${TAG}" > /dev/null 2>&1 || true
gh release delete "${TAG}" --repo "${REPO}" -y > /dev/null 2>&1 || true

git tag -a "${TAG}" -m "${TAG}"
git push origin "${TAG}" > /dev/null 2>&1

gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "${TAG}" \
    --notes "Release ${TAG}. See README.md." \
    > /dev/null

# --- 7. sha256 of the release tarball ------------------------------------
echo "==> fetching release tarball for sha256"
TAR="/tmp/sfsym-${TAG}.tar.gz"
/usr/bin/curl -sLf "https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz" -o "${TAR}"
SHA="$(/usr/bin/shasum -a 256 "${TAR}" | /usr/bin/awk '{print $1}')"
echo "    sha256: ${SHA}"

# --- 8 & 9. update tap + push --------------------------------------------
TAP_DIR="$(/usr/bin/mktemp -d /tmp/sfsym-tap.XXXXXX)"
trap '/bin/rm -rf "$STAGE" "$TAP_DIR"' EXIT
echo "==> updating ${TAP}/${FORMULA_PATH}"
git clone -q "https://github.com/${TAP}.git" "${TAP_DIR}"
/usr/bin/python3 - "${TAP_DIR}/${FORMULA_PATH}" "${VERSION}" "${SHA}" <<'PY'
import sys, re, pathlib
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = pathlib.Path(path).read_text()
src = re.sub(r'archive/refs/tags/v[^"]+\.tar\.gz', f'archive/refs/tags/v{version}.tar.gz', src)
src = re.sub(r'sha256 "[^"]+"', f'sha256 "{sha}"', src, count=1)
pathlib.Path(path).write_text(src)
PY

cd "${TAP_DIR}"
if git diff --quiet; then
    echo "    formula already up to date"
else
    git add "${FORMULA_PATH}"
    git commit -q -m "sfsym ${VERSION}"
    git push -q origin main
fi

echo
echo "released sfsym ${VERSION}"
echo "  repo:    https://github.com/${REPO}/releases/tag/${TAG}"
echo "  formula: https://github.com/${TAP}/blob/main/${FORMULA_PATH}"
echo "  install: brew reinstall yapstudios/tap/sfsym"
