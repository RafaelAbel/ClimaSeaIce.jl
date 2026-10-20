#!/usr/bin/env bash
set -euo pipefail

root=/opt/dlami/nvme/pr165-corrected-year-20261011
uri=s3://arctic-reflections-iceflow-rafael/iceflow/pr165-arctic-regional/results/pr165_corrected_bare_guard_365d_20261011
region=eu-central-1
cd "$root"
export TMPDIR=/opt/dlami/nvme/pr165-corrected-year/tmp
export JULIA_DEPOT_PATH=/opt/dlami/nvme/pr165-corrected-year/depot:/opt/sea_ice/arctic_1deg_glorys_old_thermo_2006/julia_depot
export JULIA_NUM_THREADS=2 JULIA_PKG_PRECOMPILE_AUTO=0 PR165_DT=60
export PR165_CHECKPOINT_INTERVAL_HOURS=1200

status=failed_runner
sync_pid=
sync_results() {
    for dir in preflight year; do
        if test -d "outputs/$dir"; then
            aws s3 sync "outputs/$dir/" "$uri/outputs_$dir/" --exclude '*.partial' --region "$region" --only-show-errors || return 1
        fi
    done
    for file in prepare_status.txt run_status.txt run_times.txt instantiate.log preflight.log year.log; do
        if test -f "$file"; then
            aws s3 cp "$file" "$uri/$file" --region "$region" --only-show-errors || return 1
        fi
    done
}
finish() {
    result=$?
    trap - EXIT
    set +e
    test -z "$sync_pid" || kill "$sync_pid" 2>/dev/null
    if test "$status" = failed_runner; then status="failed_runner_exit_$result"; fi
    printf '%s\n' "$status" > run_status.txt
    printf 'ended_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> run_times.txt
    sync_results
    upload_result=$?
    if test "$upload_result" -eq 0; then
        : > archive_dryrun.log
        for dir in preflight year; do
            if test -d "outputs/$dir"; then
                aws s3 sync "outputs/$dir/" "$uri/outputs_$dir/" --exclude '*.partial' --region "$region" --dryrun >> archive_dryrun.log 2>&1
            fi
        done
        if test ! -s archive_dryrun.log; then
            printf 'archive_verified_utc=%s\nfinal_status=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" > archive_status.txt
            aws s3 cp archive_status.txt "$uri/archive_status.txt" --region "$region" --only-show-errors
            if test $? -eq 0; then
                sync
                /sbin/shutdown -h now
            fi
        fi
    fi
    printf 'Archive or shutdown failed; instance left running for recovery.\n' >&2
    exit 1
}
trap finish EXIT

test -s prepare_status.txt
test ! -e outputs/preflight
test ! -e outputs/year
printf 'preparing_packages\n' > run_status.txt
printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > run_times.txt
sync_results
(
    while true; do
        sleep 900
        sync_results || true
    done
) &
sync_pid=$!

set +e
/opt/sea_ice/tools/julia-1.12.1/bin/julia --startup-file=no --project=env \
    -e 'using Pkg; Pkg.instantiate(; verbose=false)' > instantiate.log 2>&1
package_result=$?
set -e
if test "$package_result" -ne 0; then status="failed_package_install_exit_$package_result"; exit 1; fi

printf 'running_preflight\n' > run_status.txt
sync_results
export PR165_HOURS=1
set +e
/opt/sea_ice/tools/julia-1.12.1/bin/julia --startup-file=no --project=env \
    drivers/regional_forced_column_dynamics.jl outputs/preflight > preflight.log 2>&1
model_result=$?
set -e
if test "$model_result" -ne 0; then status="failed_preflight_model_exit_$model_result"; exit 1; fi
test -s outputs/preflight/summary.toml || { status=failed_preflight_summary; exit 1; }
grep -q '^hours = 1.0$' outputs/preflight/summary.toml || { status=failed_preflight_duration; exit 1; }
test "$(wc -l < outputs/preflight/hourly.csv)" -eq 2 || { status=failed_preflight_hourly; exit 1; }

printf 'running_year\n' > run_status.txt
printf 'year_started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> run_times.txt
sync_results
export PR165_HOURS=8760
set +e
/opt/sea_ice/tools/julia-1.12.1/bin/julia --startup-file=no --project=env \
    drivers/regional_forced_column_dynamics.jl outputs/year > year.log 2>&1
model_result=$?
set -e
if test "$model_result" -ne 0; then status="failed_year_model_exit_$model_result"; exit 1; fi
test -s outputs/year/summary.toml || { status=failed_year_summary; exit 1; }
grep -q '^hours = 8760.0$' outputs/year/summary.toml || { status=failed_year_duration; exit 1; }
test "$(wc -l < outputs/year/hourly.csv)" -eq 8761 || { status=failed_year_hourly; exit 1; }
test -s outputs/year/day_365.bin || { status=failed_year_snapshot; exit 1; }
status=completed_year
