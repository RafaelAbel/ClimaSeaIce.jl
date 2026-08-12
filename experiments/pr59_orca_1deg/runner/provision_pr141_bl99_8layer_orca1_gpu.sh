#!/usr/bin/env bash
set -euo pipefail

# Launch the isolated PR141 BL99 ORCA1 smoke test. The adapter itself fixes
# dynamics off and the ice grid at eight layers; this launcher deliberately
# exposes no switches for either behaviour.

PROJECT_ID="${PROJECT_ID:-rafael-sandbox-488511}"
ZONE="${ZONE:-us-central1-b}"
VM_NAME="${VM_NAME:-hens-dev-a100-arctic-pr141-smoke}"
CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/private/tmp/sea-ice-gcloud-current.Of91dI}"
RUN_LABEL="${RUN_LABEL:-pr141_bl99_8layer_orca1_5day_20260811}"
STOP_TIME="${STOP_TIME:-5days}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$EXPERIMENT_DIR/../.." && pwd)"
LOCAL_PATCH="$EXPERIMENT_DIR/patches/numericalearth_pr59_ecco_pr141_bl99_8layer_init_patch.jl"
LOCAL_CLOUD_LAUNCHER="$SCRIPT_DIR/numericalearth_pr59_launch_cloud.sh"
LOCAL_REMOTE_RUNNER="$SCRIPT_DIR/run_numericalearth_pr59_omip_on_vm.sh"
SOURCE_REV="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
SOURCE_SHORT="${SOURCE_REV:0:12}"
LOCAL_TARBALL="/private/tmp/climaseaice_${SOURCE_SHORT}.tar.gz"
REMOTE_TARBALL="/home/rafaelabel/climaseaice_${SOURCE_SHORT}.tar.gz"
REMOTE_SOURCE="/opt/Sea_ice/experiments/numericalearth_pr59/ClimaSeaIce.jl-pr141_bl99_8layer_${SOURCE_SHORT}"
JUNE8_PR59_COMMIT="bf1f9fcf8a131940ca8e6b9cd885e292c23b0ea7"
JUNE8_PR59_URL="https://codeload.github.com/NumericalEarth/NumericalEarth.jl/tar.gz/${JUNE8_PR59_COMMIT}"
JUNE8_PR59_DIR="NumericalEarth.jl-${JUNE8_PR59_COMMIT}"
LOCAL_PR59_TARBALL="/private/tmp/numericalearth_pr59_june8_${JUNE8_PR59_COMMIT:0:8}.tar.gz"
REMOTE_PR59_TARBALL="/home/rafaelabel/numericalearth_pr59_june8_${JUNE8_PR59_COMMIT:0:8}.tar.gz"
REMOTE_PR59_SOURCE="/opt/Sea_ice/experiments/numericalearth_pr59/${JUNE8_PR59_DIR}"
REMOTE_LOG="/home/rafaelabel/numericalearth_pr59_a100_ecco_${RUN_LABEL}_launcher_$(date -u +%Y%m%dT%H%M%SZ).log"

GCLOUD=(gcloud --project="$PROJECT_ID")

status="$(CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE" --format='value(status)')"
if [[ "$status" != "RUNNING" ]]; then
  CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute instances start "$VM_NAME" --zone="$ZONE"
fi

until CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute ssh "$VM_NAME" --zone="$ZONE" \
  --command='grep -q "Startup finished successfully." /var/log/climaseaice-startup.log'; do
  sleep 30
done

# The VM hydrator expects a single top-level package directory, matching the
# layout produced by GitHub's source tarballs.
git -C "$REPO_ROOT" archive --prefix="ClimaSeaIce.jl-${SOURCE_SHORT}/" \
  --format=tar.gz --output="$LOCAL_TARBALL" "$SOURCE_REV"

# This is the last PR59 source commit before the June 8 baseline run. Unlike
# the workspace metadata snapshot, this upstream archive includes the complete
# NumericalEarth source tree and cannot move underneath a retry.
curl -L --fail --silent --show-error "$JUNE8_PR59_URL" -o "$LOCAL_PR59_TARBALL"

CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute scp \
  "$LOCAL_PATCH" "$LOCAL_CLOUD_LAUNCHER" "$LOCAL_REMOTE_RUNNER" \
  "$VM_NAME:/home/rafaelabel/" --zone="$ZONE"
CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute scp \
  "$LOCAL_TARBALL" "$VM_NAME:$REMOTE_TARBALL" --zone="$ZONE"
CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute scp \
  "$LOCAL_PR59_TARBALL" "$VM_NAME:$REMOTE_PR59_TARBALL" --zone="$ZONE"

CLOUDSDK_CONFIG="$CLOUDSDK_CONFIG" "${GCLOUD[@]}" compute ssh "$VM_NAME" --zone="$ZONE" --command="
  chmod +x /home/rafaelabel/run_numericalearth_pr59_omip_on_vm.sh &&
  nohup env \
    OMIP_ARCH='gpu' \
    OMIP_CONFIG='orca' \
    OMIP_STOP_TIME='${STOP_TIME}' \
    OMIP_DT='20minutes' \
    OMIP_DIAGNOSTICS='true' \
    OMIP_BACKEND_SIZE='4' \
    OMIP_START_DATE='2006-01-01T00:00:00' \
    OMIP_END_DATE='2006-12-31T00:00:00' \
    OMIP_INIT_SOURCE='ecco' \
    OMIP_HYDRATE_FROM_BUCKET='true' \
    OMIP_BUCKET_NAME='sea_ice' \
    OMIP_ECCO_BUCKET_PREFIX='inputs/tripolar_ecco4/2006/ecco4' \
    OMIP_JRA55_BUCKET_PREFIX='inputs/tripolar_glorys_jra55/2006/jra55' \
    OMIP_UPLOAD_OUTPUTS='true' \
    OMIP_OUTPUT_BUCKET_PREFIX='outputs/numericalearth_pr59/a100_ecco_${RUN_LABEL}' \
    OMIP_SHUTDOWN_ON_EXIT='true' \
    OMIP_SHUTDOWN_ON_FAILURE='false' \
    OMIP_LAUNCHER_LOG='${REMOTE_LOG}' \
    OMIP_OUTPUT_DIR='/home/rafaelabel/numericalearth_pr59_a100_ecco_${RUN_LABEL}' \
    OMIP_SEA_ICE_THERMODYNAMICS='pr141_bl99' \
    OMIP_CLEAN_PR59_BASELINE='true' \
    OMIP_WITH_SNOW='false' \
    OMIP_WITH_ICE_DYNAMICS='false' \
    CLIMASEAICE_VARIANT='pr141_bl99_8layer_${SOURCE_SHORT}' \
    CLIMASEAICE_TARBALL='${REMOTE_TARBALL}' \
    CLIMASEAICE_SRC='${REMOTE_SOURCE}' \
    TARBALL_PATH='${REMOTE_PR59_TARBALL}' \
    SRC_ROOT='${REMOTE_PR59_SOURCE}' \
    PROJECT_DIR='${REMOTE_PR59_SOURCE}/experiments/OMIPSimulations' \
    REFRESH_PR_SOURCE='true' \
    BIHARMONIC='50days' \
    CORRECTED='true' \
    SNOW='false' \
    KSKEW='800' \
    KSYMM='800' \
    PATCH_SCRIPT='/home/rafaelabel/numericalearth_pr59_ecco_pr141_bl99_8layer_init_patch.jl' \
    LAUNCH_SCRIPT='/home/rafaelabel/numericalearth_pr59_launch_cloud.sh' \
    bash /home/rafaelabel/run_numericalearth_pr59_omip_on_vm.sh \
    >'${REMOTE_LOG}' 2>&1 &
"

echo "Launched PR141 BL99 eight-layer ORCA1 ${STOP_TIME} GPU smoke test."
echo "VM: ${VM_NAME} (${ZONE})"
echo "Source: ${SOURCE_REV}"
echo "Log: ${REMOTE_LOG}"
