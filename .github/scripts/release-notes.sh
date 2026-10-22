#!/bin/bash
# Check a release tag against the repo, then print its release notes.
#
#   .github/scripts/release-notes.sh v1.4.0 > notes.md
#
# Fails (non-zero, message on stderr) unless the tag is vX.Y.Z, Info.plist's
# CFBundleShortVersionString is the same version, and CHANGELOG.md has a
# non-empty "## [X.Y.Z]" section. Those are the steps of the release process
# that are easy to forget, and a release cut without them is wrong in ways
# that are awkward to fix once people have downloaded it.
set -euo pipefail
cd "$(dirname "$0")/../.."

TAG="${1:?usage: release-notes.sh vX.Y.Z}"
fail() { echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || fail "tag '$TAG' isn't vX.Y.Z"
VERSION="${BASH_REMATCH[1]}"

# Info.plist has used both "1.3" and "1.2.0" styles, so pad a missing patch
# number before comparing rather than failing on the spelling.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' DeskBar/Info.plist)"
NORMALIZED="$PLIST_VERSION"
[[ "$NORMALIZED" =~ ^[0-9]+\.[0-9]+$ ]] && NORMALIZED="$NORMALIZED.0"
[[ "$NORMALIZED" == "$VERSION" ]] \
    || fail "tag is $VERSION but DeskBar/Info.plist says $PLIST_VERSION — bump CFBundleShortVersionString"

# The section runs from its "## [X.Y.Z]" heading to the next "## [" heading,
# or to the link references at the bottom of the file.
SECTION="$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    on { print }
' CHANGELOG.md)"
[[ -n "$(tr -d '[:space:]' <<<"$SECTION")" ]] \
    || fail "CHANGELOG.md has no '## [$VERSION]' section (or it's empty) — move the Unreleased entries under it"

# Trim leading/trailing blank lines from the section.
sed -e '/./,$!d' <<<"$SECTION" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'

cat <<EOF

## Install

Download \`DeskBar-$VERSION.zip\` below, unzip it, and move \`DeskBar.app\` to
\`~/Applications\` (or \`/Applications\`). The app is ad-hoc signed, not notarized, so clear
macOS's quarantine flag before the first launch:

\`\`\`bash
xattr -dr com.apple.quarantine ~/Applications/DeskBar.app
\`\`\`

Requires macOS 13 or later on Apple silicon. First launch asks for Bluetooth permission.
EOF
