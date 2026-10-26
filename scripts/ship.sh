#!/usr/bin/env bash
# Ship a Presenter release: version bump, notarized DMG, signed Sparkle feed, tag, and GitHub Release.
# Installed copies find the new version in the feed and install it when Presenter quits.
# Usage: scripts/ship.sh [--minor|--major] [--dry-run]
#   (default)  bump the patch version
#   --dry-run  check the preconditions and print the next version; change nothing
# Environment: SPARKLE_ACCOUNT (default presenter), NOTARY_PROFILE (default conduit-notary)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="Marceswan/mac-presenter"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
: "${SPARKLE_ACCOUNT:=presenter}"
: "${NOTARY_PROFILE:=conduit-notary}"
export NOTARY_PROFILE

BUMP=patch
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --minor) BUMP=minor ;;
    --major) BUMP=major ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: scripts/ship.sh [--minor|--major] [--dry-run]" >&2; exit 2 ;;
  esac
done

fail() { echo "ship: $*" >&2; exit 1; }
step() { echo "::progress::$1/6 $2" >&2; }
yaml_value() { sed -nE "s/^ *$1: *\"?([^\"]+)\"?\$/\\1/p" | head -1; }

step 1 "Checking preconditions"
if [ "$DRY_RUN" = 0 ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "switch to the main branch"
  [ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
  git fetch -q origin main --tags
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "push main first (HEAD differs from origin/main)"
fi
gh auth status >/dev/null 2>&1 || fail "gh is not logged in (run: gh auth login)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notary profile '$NOTARY_PROFILE' does not work (see xcrun notarytool store-credentials)"
BIN="$(scripts/sparkle-tools.sh)"
KEYCHAIN_KEY="$("$BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" \
  || fail "no Sparkle signing key for account '$SPARKLE_ACCOUNT' in the keychain (see README: Release)"
PLIST_KEY="$(yaml_value SUPublicEDKey < project.yml)"
[ -n "$PLIST_KEY" ] || fail "SUPublicEDKey is missing from project.yml"
[ "$KEYCHAIN_KEY" = "$PLIST_KEY" ] \
  || fail "the keychain key for account '$SPARKLE_ACCOUNT' does not match SUPublicEDKey in project.yml"

step 2 "Computing the version"
PREV_TAG="$(git tag -l 'v*' | sort -V | tail -1)"
[ -n "$PREV_TAG" ] || fail "no v* tag found"
gh release view "$PREV_TAG" -R "$REPO" >/dev/null 2>&1 \
  || fail "tag $PREV_TAG has no GitHub Release (an earlier run stopped after the tag push). Remove the tag and run again: git push origin :refs/tags/$PREV_TAG && git tag -d $PREV_TAG"
IFS=. read -r MAJOR MINOR PATCH <<<"${PREV_TAG#v}"
case "$BUMP" in
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  *) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac
PREV_BUILD="$(git show "$PREV_TAG:project.yml" | yaml_value CURRENT_PROJECT_VERSION)"
[ -n "$PREV_BUILD" ] || fail "CURRENT_PROJECT_VERSION is missing from $PREV_TAG:project.yml"
BUILD=$((PREV_BUILD + 1))
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "tag $TAG already exists. If an earlier run stopped after the tag push, remove it: git push origin :refs/tags/$TAG && git tag -d $TAG. If $TAG is a real release, ship a higher version."
fi
CUR_VERSION="$(yaml_value MARKETING_VERSION < project.yml)"
CUR_BUILD="$(yaml_value CURRENT_PROJECT_VERSION < project.yml)"
echo "ship: next version $VERSION (build $BUILD) after $PREV_TAG" >&2
if [ "$CUR_VERSION" = "$VERSION" ] && [ "$CUR_BUILD" = "$BUILD" ]; then
  echo "ship: project.yml already has $VERSION (build $BUILD)" >&2
  NEEDS_BUMP=0
else
  echo "ship: project.yml changes from $CUR_VERSION (build $CUR_BUILD)" >&2
  NEEDS_BUMP=1
fi
[ "$DRY_RUN" = 0 ] || exit 0

step 3 "Bumping the version"
if [ "$NEEDS_BUMP" = 1 ]; then
  sed -i '' -E "s/^( *MARKETING_VERSION: *).*/\\1\"$VERSION\"/; s/^( *CURRENT_PROJECT_VERSION: *).*/\\1\"$BUILD\"/" project.yml
  [ "$(yaml_value MARKETING_VERSION < project.yml)" = "$VERSION" ] || fail "could not set MARKETING_VERSION"
  [ "$(yaml_value CURRENT_PROJECT_VERSION < project.yml)" = "$BUILD" ] || fail "could not set CURRENT_PROJECT_VERSION"
  git commit -q -m "Release $VERSION (build $BUILD)" project.yml
  git push -q origin main
fi
SHA="$(git rev-parse HEAD)"

step 4 "Building, signing, and notarizing"
scripts/release.sh
DMG="$ROOT/build/release/Presenter-$VERSION.dmg"
[ -f "$DMG" ] || fail "expected $DMG"

step 5 "Signing the update feed"
STAGE="$ROOT/build/release/appcast-stage"
NOTES_FILE="$ROOT/build/release/notes-$VERSION.md"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
SUBJECTS="$(git log --format=%s "$PREV_TAG..$SHA" | grep -v -e '^Release ' -e '^Merge ' || true)"
[ -n "$SUBJECTS" ] || SUBJECTS="Presenter $VERSION"
sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<p>&</p>|' <<<"$SUBJECTS" > "$STAGE/Presenter-$VERSION.html"
sed 's/^/- /' <<<"$SUBJECTS" > "$NOTES_FILE"
"$BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$STAGE/appcast.xml" "$STAGE"
grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\"" "$STAGE/appcast.xml" \
  || fail "the feed does not name build $BUILD (check CFBundleVersion in the DMG)"

step 6 "Publishing and checking the live feed"
[ "$(git rev-parse HEAD)" = "$SHA" ] || fail "HEAD moved during the build (was $SHA). Nothing is tagged or published."
git tag -a "$TAG" -m "Presenter $VERSION" -m "build=$BUILD" "$SHA"
if ! git push -q origin "$TAG"; then
  git tag -d "$TAG" >/dev/null
  fail "the tag push failed. The local tag is removed. Nothing is published."
fi
if ! gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" -R "$REPO" \
     --title "Presenter $VERSION" --notes-file "$NOTES_FILE" --latest; then
  fail "the release upload failed. Retry: gh release create $TAG '$DMG' '$STAGE/appcast.xml' -R $REPO --title 'Presenter $VERSION' --notes-file '$NOTES_FILE' --latest. To abandon: git push origin :refs/tags/$TAG && git tag -d $TAG"
fi
DMG_URL="https://github.com/$REPO/releases/download/$TAG/Presenter-$VERSION.dmg"
LIVE=0
FEED_BODY=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  FEED_BODY="$(curl -fsSL "$FEED_URL" || true)"
  if grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\"" <<<"$FEED_BODY" \
     && curl -fsSL -r 0-0 -o /dev/null "$DMG_URL"; then
    LIVE=1
    break
  fi
  sleep 5
done
if [ "$LIVE" != 1 ]; then
  echo "ship: the live feed lists: $(grep -o '<sparkle:version>[^<]*' <<<"$FEED_BODY" | tr '\n' ' ')" >&2
  fail "the feed at $FEED_URL or the DMG at $DMG_URL does not serve build $BUILD after 60 s. The release stays in place for inspection."
fi

rm -rf "$STAGE" "$NOTES_FILE"
echo "Shipped Presenter $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
