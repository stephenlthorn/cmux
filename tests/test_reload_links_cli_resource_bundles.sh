#!/usr/bin/env bash
# Regression test: Xcode copies SwiftPM resource bundles into the app after
# every script phase, so on a fresh tagged build build-app-bundled-resources.sh
# finds no bundles to link beside the CLI. The bundled `cmux` CLI then aborts
# in Bundle.module ("unable to find bundle named CmuxFoundation_CmuxFoundation")
# on `cmux --help` and every usage message. reload.sh must link them after the
# build, before it signs the app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
LIB="$ROOT_DIR/scripts/lib/swiftpm-resource-bundles.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LIB" ]] || fail "missing $LIB"
# shellcheck source=scripts/lib/swiftpm-resource-bundles.sh
source "$LIB"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
RESOURCES="$TMP_DIR/cmux DEV probe.app/Contents/Resources"
mkdir -p "$RESOURCES/bin/helper-dir" \
  "$RESOURCES/CmuxFoundation_CmuxFoundation.bundle/Contents" \
  "$RESOURCES/Bonsplit_Bonsplit.bundle/Contents"
printf 'localized\n' > "$RESOURCES/CmuxFoundation_CmuxFoundation.bundle/Contents/Localizable.strings"
# A real copy left by an older build, and a link to a bundle that is gone.
mkdir -p "$RESOURCES/bin/Bonsplit_Bonsplit.bundle/Contents"
ln -s ../Removed_Removed.bundle "$RESOURCES/bin/Removed_Removed.bundle"

cmux_link_cli_resource_bundles "$RESOURCES"

for name in CmuxFoundation_CmuxFoundation Bonsplit_Bonsplit; do
  link="$RESOURCES/bin/$name.bundle"
  [[ -L "$link" && "$(readlink "$link")" == "../$name.bundle" ]] \
    || fail "$name.bundle is not linked beside the CLI"
done
[[ "$(cat "$RESOURCES/bin/CmuxFoundation_CmuxFoundation.bundle/Contents/Localizable.strings")" == localized ]] \
  || fail "the CLI link does not resolve to the app's bundle"
[[ ! -e "$RESOURCES/bin/Removed_Removed.bundle" && ! -L "$RESOURCES/bin/Removed_Removed.bundle" ]] \
  || fail "a link to a removed bundle was kept"
[[ -d "$RESOURCES/bin/helper-dir" ]] || fail "an unrelated helper directory was removed"

# Idempotent: a second run leaves the same links.
cmux_link_cli_resource_bundles "$RESOURCES"
[[ "$(readlink "$RESOURCES/bin/CmuxFoundation_CmuxFoundation.bundle")" == "../CmuxFoundation_CmuxFoundation.bundle" ]] \
  || fail "a second run changed the link"

# reload.sh links the bundles after Xcode's copy and before codesign.
link_line="$(grep -n 'cmux_link_cli_resource_bundles "\$APP_PATH/Contents/Resources"' "$RELOAD" | head -1 | cut -d: -f1)"
sign_line="$(grep -n '/usr/bin/codesign --force --sign - ' "$RELOAD" | head -1 | cut -d: -f1)"
[[ -n "$link_line" ]] || fail "reload.sh never links the CLI resource bundles"
[[ -n "$sign_line" && "$link_line" -lt "$sign_line" ]] || fail "reload.sh links the bundles after signing"

# The build phase shares the same helper instead of a copy of it.
grep -q 'swiftpm-resource-bundles.sh' "$ROOT_DIR/scripts/build-app-bundled-resources.sh" \
  || fail "build-app-bundled-resources.sh does not use the shared helper"

echo "PASS: CLI resource bundles are linked after the build"
