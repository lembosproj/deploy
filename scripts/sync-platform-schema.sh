#!/usr/bin/env bash
# Copies the platform contract's JSON schema into the chart's values.schema.json, as its `platform` section.
#
# The platform generates contracts/platform-values.schema.json from PlatformConfig and its release publishes
# the file as a public OCI artifact beside the images, ghcr.io/lembosproj/platform/values-schema:<version>;
# the chart does not know the type, so it takes the artifact. Run this with no argument when Chart.yaml's
# appVersion moves, and it pulls the contract of that release (needs `oras`). Give it a path to take a local
# checkout's copy instead — for a chart change that rides alongside a platform change not yet released.
#
# The chart workflow does the same pull and fails when the section differs, so the copy cannot quietly lag.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$root/charts/lembos/values.schema.json"
source="${1:-}"

if [[ -z "$source" ]]; then
    version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$root/charts/lembos/Chart.yaml")"
    artifact="ghcr.io/lembosproj/platform/values-schema:${version}"
    pulled="$(mktemp -d)"
    trap 'rm -rf "$pulled"' EXIT
    oras pull "$artifact" -o "$pulled" > /dev/null
    source="$pulled/platform-values.schema.json"
    from="$artifact"
else
    from="$source"
fi

updated="$(jq --argjson platform "$(cat "$source")" '.properties.platform = $platform' "$schema")"
printf '%s\n' "$updated" > "$schema"

echo "Wrote the platform section of $schema from $from"
