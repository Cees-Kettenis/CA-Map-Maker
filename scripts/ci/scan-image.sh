#!/usr/bin/env bash
set -euo pipefail
image=$1
scan_dir=${RUNNER_TEMP:-/tmp}/trivy-report
mkdir -p "$scan_dir" "${RUNNER_TEMP:-/tmp}/trivy-cache"
docker image save -o "$scan_dir/image.tar" "$image"
trap 'rm -f "$scan_dir/image.tar"' EXIT
scan=(docker run --rm -v "$scan_dir:/scan" -v "${RUNNER_TEMP:-/tmp}/trivy-cache:/cache" "$TRIVY_IMAGE" image --input /scan/image.tar --cache-dir /cache --scanners vuln --parallel 2 --timeout 20m --disable-telemetry --skip-version-check --ignorefile '' --config '')
"${scan[@]}" --format json --output /scan/report.json
python3 scripts/ci/report-summary.py "$scan_dir/report.json" >> "$GITHUB_STEP_SUMMARY"
# Unfixed issues remain in the full report. Available HIGH/CRITICAL fixes block publication.
"${scan[@]}" --skip-db-update --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 --format table
