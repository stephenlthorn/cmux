# shellcheck shell=bash
# SwiftPM places a package's processed resource bundle beside the app's other
# resources. The bundled CLI lives one directory deeper in Resources/bin, and
# Bundle.module resolves relative to that executable's resource directory.
# Link each bundle beside the CLI to the app's copy, so package resources work
# when the CLI is invoked directly from the app bundle and ship only once. The
# links are relative and stay inside the bundle, so code signing seals them as
# links. This is intentionally generic: adding resources to another package
# must not require another packaging allowlist.
#
# Xcode copies package bundles into the app after every script phase, so the
# build phase alone finds none on a fresh build; reload.sh calls this again
# once the build has finished, before it signs the app.
cmux_link_cli_resource_bundles() {
  local resources_dir="$1"
  local bin_dir="$resources_dir/bin" source name destination
  mkdir -p "$bin_dir"
  for source in "$resources_dir"/*.bundle; do
    [ -d "$source" ] || continue
    name="${source##*/}"
    destination="$bin_dir/$name"
    if [ -L "$destination" ] && [ "$(readlink "$destination")" = "../$name" ]; then
      continue
    fi
    # Replace a real copy left by an older build.
    rm -rf "$destination"
    ln -s "../$name" "$destination"
  done

  # Remove links to package bundles that disappeared from the app resource
  # directory, while leaving unrelated helper directories in Resources/bin.
  for destination in "$bin_dir"/*.bundle; do
    [ -d "$destination" ] || [ -L "$destination" ] || continue
    name="${destination##*/}"
    [ -d "$resources_dir/$name" ] || rm -rf "$destination"
  done
}
