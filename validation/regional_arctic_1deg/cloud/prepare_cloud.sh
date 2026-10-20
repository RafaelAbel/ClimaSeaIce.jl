#!/usr/bin/env bash
set -euo pipefail

region=eu-central-1
root=/opt/dlami/nvme/pr165-corrected-year-20261011
code=s3://arctic-reflections-iceflow-rafael/iceflow/pr165-arctic-regional/code
bundle_sha=74c2d50fc2e9fb07d81f9b4cebd93b0ac3de055ad36ec90f18e82141c73dba6c
source_sha=e6f112a24719cd28f422a9ca80c5c51523746ad6a0a3648922c614d7d816bf19
driver_sha=782875fd28c35d1e2e0ded33eb2090d2f10b406729b6e968f2131c047e5883b4

test ! -e "$root"
mkdir -p "$root" /opt/dlami/nvme/pr165-corrected-year/tmp /opt/dlami/nvme/pr165-corrected-year/depot
aws s3 cp "$code/native_pr165_flux_20261006_365d_bundle.tar.gz" "$root/bundle.tar.gz" --region "$region" --only-show-errors
echo "$bundle_sha  $root/bundle.tar.gz" | sha256sum -c -
tar --warning=no-unknown-keyword -xzf "$root/bundle.tar.gz" -C "$root"

aws s3 cp "$code/fixed_surface_solver_80d_20261008_source.tar.gz" "$root/source_fixed.tar.gz" --region "$region" --only-show-errors
echo "$source_sha  $root/source_fixed.tar.gz" | sha256sum -c -
rm -rf "$root/source"
mkdir "$root/source"
tar --warning=no-unknown-keyword -xzf "$root/source_fixed.tar.gz" -C "$root/source"

aws s3 cp "$code/pr165_corrected_bare_guard_20261011_driver.jl" "$root/drivers/regional_forced_column_dynamics.jl" --region "$region" --only-show-errors
aws s3 cp "$code/pr165_corrected_bare_guard_20261011_run.sh" "$root/run_corrected_year.sh" --region "$region" --only-show-errors
echo "$driver_sha  $root/drivers/regional_forced_column_dynamics.jl" | sha256sum -c -
test -x /opt/sea_ice/tools/julia-1.12.1/bin/julia
test -s "$root/arctic-thermo/input/tas.f32"
test -s "$root/env/Manifest.toml"
printf 'prepared_utc=%s\ninstance_id=%s\nsource_sha256=%s\nbundle_sha256=%s\ndriver_sha256=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "i-0510593911999cad8" \
    "$source_sha" "$bundle_sha" "$driver_sha" > "$root/prepare_status.txt"
cat "$root/prepare_status.txt"
