#!/usr/bin/env bash
# Builds an unsigned iOS Simulator .app with xcodebuild.
#
# Inputs (environment):
#   SIMPR_WORKSPACE | SIMPR_PROJECT   one of them, or neither to let xcodebuild pick
#   SIMPR_SCHEME                      required
#   SIMPR_CONFIGURATION               default Debug
#   SIMPR_ARCHS                       default "arm64 x86_64" (universal)
#   SIMPR_EXTRA_XCODEBUILD_ARGS       extra arguments, split like a shell would (quotes allowed, no expansion)
#   SIMPR_APP_NAME                    which .app to pick when the build produces several
#   SIMPR_DERIVED_DATA                derived data path
# Outputs (GITHUB_OUTPUT): app-path, architectures
set -euo pipefail

: "${SIMPR_SCHEME:?scheme is required}"
CONFIGURATION="${SIMPR_CONFIGURATION:-Debug}"
ARCHS="${SIMPR_ARCHS:-arm64 x86_64}"
DERIVED_DATA="${SIMPR_DERIVED_DATA:-${RUNNER_TEMP:-/tmp}/simpr-derived-data}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/stdout}"

container=()
if [[ -n "${SIMPR_WORKSPACE:-}" && -n "${SIMPR_PROJECT:-}" ]]; then
  echo "::error::Set either workspace or project, not both." >&2
  exit 1
elif [[ -n "${SIMPR_WORKSPACE:-}" ]]; then
  container=(-workspace "$SIMPR_WORKSPACE")
elif [[ -n "${SIMPR_PROJECT:-}" ]]; then
  container=(-project "$SIMPR_PROJECT")
fi

# Split extra args without evaluating them (no globbing, no variable expansion).
extra=()
if [[ -n "${SIMPR_EXTRA_XCODEBUILD_ARGS:-}" ]]; then
  while IFS= read -r -d '' arg; do
    extra+=("$arg")
  done < <(python3 -c 'import shlex, sys
for a in shlex.split(sys.argv[1]):
    sys.stdout.write(a + "\0")' "$SIMPR_EXTRA_XCODEBUILD_ARGS")
fi

formatter=(cat)
if command -v xcbeautify >/dev/null 2>&1; then
  formatter=(xcbeautify --renderer github-actions)
fi

run_build() {
  local archs="$1"
  echo "::group::xcodebuild (ARCHS=$archs)"
  set +e
  xcodebuild build \
    ${container[@]+"${container[@]}"} \
    -scheme "$SIMPR_SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ${extra[@]+"${extra[@]}"} 2>&1 | "${formatter[@]}"
  local status=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  return "$status"
}

if ! run_build "$ARCHS"; then
  if [[ "$ARCHS" == *" "* ]]; then
    echo "::warning::Universal build ($ARCHS) failed, often because a dependency ships without x86_64 simulator slices. Retrying with arm64 only."
    run_build "arm64"
  else
    exit 1
  fi
fi

products="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator"
apps=()
while IFS= read -r -d '' app; do
  apps+=("$app")
done < <(find "$products" -maxdepth 1 -name '*.app' -type d -print0 2>/dev/null)

app=""
if [[ -n "${SIMPR_APP_NAME:-}" ]]; then
  for candidate in ${apps[@]+"${apps[@]}"}; do
    if [[ "$(basename "$candidate" .app)" == "$SIMPR_APP_NAME" ]]; then app="$candidate"; fi
  done
elif [[ ${#apps[@]} -eq 1 ]]; then
  app="${apps[0]}"
elif [[ ${#apps[@]} -gt 1 ]]; then
  # Prefer the app whose name matches the scheme, then the largest bundle.
  for candidate in "${apps[@]}"; do
    if [[ "$(basename "$candidate" .app)" == "$SIMPR_SCHEME" ]]; then app="$candidate"; fi
  done
  if [[ -z "$app" ]]; then
    app="$(du -sk "${apps[@]}" | sort -rn | head -1 | cut -f2-)"
    echo "::warning::Several .app bundles were built; picked $(basename "$app"). Set the app-name input to choose."
  fi
fi

if [[ -z "$app" ]]; then
  echo "::error::No .app found in $products. Check the scheme and configuration." >&2
  exit 1
fi

executable="$(/usr/bin/plutil -extract CFBundleExecutable raw "$app/Info.plist")"
built_archs="$(lipo -archs "$app/$executable")"
echo "Built $(basename "$app") for: $built_archs"
{
  echo "app-path=$app"
  echo "architectures=$built_archs"
} >> "$OUTPUT_FILE"
