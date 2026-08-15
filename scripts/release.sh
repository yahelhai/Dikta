#!/bin/bash
# Tag a release and publish it as one step that cannot half-happen.
# Usage: scripts/release.sh <version> [--check] [--title <text>] [--notes <file>]
#
# Releases used to be four separate manual acts — a "Release vX" commit, a
# merge, `git tag -a`, `gh release create` — held together only by doing them
# in one sitting. v1.4's merge landed two days after its release commit, and
# the tag never happened: main carried an Info.plist claiming 1.4 with no tag
# and no release behind it, and the CHANGELOG heading had no link line. Each
# check below is one of the states that gap left behind.
#
# --check runs the checks and stops, so "is this releasable?" costs nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=""
CHECK_ONLY=0
TITLE=""
NOTES_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --title) TITLE="${2:-}"; shift 2 ;;
        --notes) NOTES_FILE="${2:-}"; shift 2 ;;
        -*) echo "release: unknown option '$1'" >&2; exit 2 ;;
        *) VERSION="${1#v}"; shift ;;
    esac
done

usage() {
    echo "usage: scripts/release.sh <version> [--check] [--title <text>] [--notes <file>]" >&2
    exit 2
}
fail() { echo "release: $*" >&2; exit 1; }

[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "'$VERSION' is not X.Y or X.Y.Z"

echo "==> checking v$VERSION"

# gh is only needed by the last step, but a tag pushed before discovering it is
# missing leaves exactly the half-done release this script exists to prevent.
command -v gh >/dev/null 2>&1 || fail "gh is not installed — the release step needs it"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated — run: gh auth login"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || fail "on '$BRANCH' — a release is tagged on the merge commit in main"

[ -z "$(git status --porcelain)" ] || fail "working tree is dirty — commit or stash first"

git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "main is not level with origin/main — pull or push first"

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    Resources/Info.plist 2>/dev/null || true)"
[ "$PLIST_VERSION" = "$VERSION" ] \
    || fail "Info.plist says '$PLIST_VERSION' but you asked for '$VERSION' — the app would ship a version no tag matches"

grep -q "^## \[$VERSION\]" CHANGELOG.md \
    || fail "CHANGELOG.md has no '## [$VERSION]' section"

grep -q "^\[$VERSION\]: https" CHANGELOG.md \
    || fail "CHANGELOG.md has no '[$VERSION]: https://…' line — the heading renders unlinked without it"

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    fail "tag v$VERSION already exists locally"
fi
[ -z "$(git ls-remote --tags origin "refs/tags/v$VERSION")" ] \
    || fail "tag v$VERSION already exists on origin"

# Notes: the CHANGELOG section for this version, unless a richer hand-written
# file is given. The tag message keeps the "Dikta vX — subtitle" first line the
# earlier tags use.
NOTES="$(mktemp)"
TAG_MSG="$(mktemp)"
trap 'rm -f "$NOTES" "$TAG_MSG"' EXIT

if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || fail "no such notes file: $NOTES_FILE"
    cat "$NOTES_FILE" > "$NOTES"
else
    awk -v heading="## [$VERSION]" '
        index($0, heading) == 1 { inside = 1; next }
        inside && /^## \[/ { exit }
        inside { print }
    ' CHANGELOG.md > "$NOTES"
fi
[ -s "$NOTES" ] || fail "the release notes came out empty"

{ echo "${TITLE:-Dikta v$VERSION}"; echo; cat "$NOTES"; } > "$TAG_MSG"

if [ "$CHECK_ONLY" = 1 ]; then
    echo "==> ok: v$VERSION is ready to tag at $(git rev-parse --short HEAD)"
    exit 0
fi

echo "==> tagging v$VERSION at $(git rev-parse --short HEAD)"
git tag -a "v$VERSION" -F "$TAG_MSG"

echo "==> pushing the tag"
git push -q origin "v$VERSION"

echo "==> creating the GitHub release"
gh release create "v$VERSION" --title "${TITLE:-v$VERSION}" --notes-file "$NOTES"

echo "==> released v$VERSION"
