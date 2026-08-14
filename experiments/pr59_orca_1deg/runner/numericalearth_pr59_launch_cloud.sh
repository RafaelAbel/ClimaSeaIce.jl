#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: numericalearth_pr59_launch_cloud.sh <config>

Configs:
  halfdegree
  orca
  tenthdegree

Environment:
  CLOUD_ARCH=cpu|gpu
  BIHARMONIC=50days
  CORRECTED=true|false
  SNOW=true|false
  KSKEW=800
  KSYMM=800
  KSYMMETRIC=800
  BIHVISC=1e12
  CLOSURE=catke|simple|nori|rbvd|kpp|nemo_tke
  WIND_VELOCITY=true|false
  SHEAR_GUST=true|false
  MIN_SALINITY=1
  NORMALIZE_SALINITY=true|false
  CATKE_CWUSTAR=5.0
  FORCING_DIR=/path/to/jra55
  STAGING_DIR=/path/to/staging
  RESTORING_DIR=/path/to/woa
  OMIP_GLORYS_DIR=/path/to/glorys
  OUTPUT_DIR=/path/to/output
  BACKEND_SIZE=4
  STOP_TIME=1day
  STOP_ITERATION=1
  DIAGNOSTICS=true|false
  PROFILE=true|false
  OMIP_FILE_SPLITTING_INTERVAL=5days
USAGE
}

CONFIG="${1:-}"
if [[ -z "$CONFIG" ]]; then
  usage
  exit 1
fi

case "$CONFIG" in
  halfdegree|half_degree)
    CONFIG="halfdegree"
    ;;
  orca|tenthdegree)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown config: $CONFIG" >&2
    exit 1
    ;;
esac

case "$CONFIG" in
  halfdegree)
    DEFAULT_KSKEW=250
    DEFAULT_KSYMM=100
    NZ=70
    DEFAULT_DT="30minutes"
    DEFAULT_BIHARMONIC="40days"
    DEFAULT_DZ_TOP="2.0"
    DEFAULT_ARCH="GPU()"
    DEFAULT_EXTRA_USING=""
    DEFAULT_FILE_SPLIT=""
    DEFAULT_STOP_CMD=$'sim.stop_time = 300 * 365days\nrun!(sim; pickup = :latest)'
    ;;
  orca)
    DEFAULT_KSKEW=500
    DEFAULT_KSYMM=250
    NZ=70
    DEFAULT_DT="20minutes"
    DEFAULT_BIHARMONIC="10days"
    DEFAULT_DZ_TOP="1.5"
    DEFAULT_ARCH="GPU()"
    DEFAULT_EXTRA_USING=""
    DEFAULT_FILE_SPLIT=""
    DEFAULT_STOP_CMD=$'sim.stop_time = 720day\nrun!(sim; pickup = :latest)\n\nsim.stop_time = 300 * 365days\nsim.Δt = 30minutes\n\nrun!(sim)'
    ;;
  tenthdegree)
    DEFAULT_KSKEW=0
    DEFAULT_KSYMM=0
    NZ=100
    DEFAULT_DT="6minutes"
    DEFAULT_BIHARMONIC="nothing"
    DEFAULT_DZ_TOP="1.5"
    DEFAULT_ARCH="Distributed(GPU(), partition = Partition(1, 4))"
    DEFAULT_EXTRA_USING="using Oceananigans.DistributedComputations"
    DEFAULT_FILE_SPLIT="file_splitting_interval = 180days,"
    DEFAULT_STOP_CMD=$'sim.stop_time = 181days\nrun!(sim)\n\nsim.Δt = 15minutes\nsim.stop_time = 300 * 365days\nrun!(sim; pickup = true)'
    ;;
esac

JULIA="${JULIA:-/opt/Sea_ice/tools/julia-1.12.1/bin/julia}"
PROJECT_DIR="${PROJECT_DIR:-/opt/Sea_ice/experiments/numericalearth_pr59/NumericalEarth.jl-refs-pull-59-head/experiments/OMIPSimulations}"
PATCH_PATH="${PATCH_PATH:-/home/rafaelabel/numericalearth_pr59_glorys_init_patch.jl}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
FORCING_DIR="${FORCING_DIR:-$PWD/forcing_data}"
STAGING_DIR="${STAGING_DIR:-}"
RESTORING_DIR="${RESTORING_DIR:-$PWD/woa_climatology}"
OMIP_GLORYS_DIR="${OMIP_GLORYS_DIR:-$PWD/glorys}"
THREADS="${THREADS:-8}"
JULIA_OPTLEVEL="${JULIA_OPTLEVEL:-}"
JULIA_COMPILE_MODE="${JULIA_COMPILE_MODE:-}"
JULIA_COMPILED_MODULES="${JULIA_COMPILED_MODULES:-}"
JULIA_PKGIMAGES="${JULIA_PKGIMAGES:-}"
JULIA_INLINE="${JULIA_INLINE:-}"
JULIA_SYSIMAGE="${JULIA_SYSIMAGE:-}"
CLOUD_ARCH="${CLOUD_ARCH:-gpu}"
START_DATE="${OMIP_START_DATE:-2006-01-01T00:00:00}"
END_DATE="${OMIP_END_DATE:-2006-12-31T00:00:00}"
DIAGNOSTICS="${DIAGNOSTICS:-true}"
FILE_SPLITTING_INTERVAL="${OMIP_FILE_SPLITTING_INTERVAL:-360days}"
PROFILE="${PROFILE:-false}"
BACKEND_SIZE="${BACKEND_SIZE:-}"
ARTIFICIAL_REICING="${OMIP_ARTIFICIAL_REICING:-false}"
ORCA_ACTIVE_CELLS_MAP="${OMIP_ORCA_ACTIVE_CELLS_MAP:-false}"
REICING_LON_MIN="${OMIP_REICING_LON_MIN:--140.5}"
REICING_LON_MAX="${OMIP_REICING_LON_MAX:--137.5}"
REICING_LAT_MIN="${OMIP_REICING_LAT_MIN:-69.9}"
REICING_LAT_MAX="${OMIP_REICING_LAT_MAX:-71.0}"
REICING_INCREMENT_M="${OMIP_REICING_INCREMENT_M:-0.5}"
REICING_MIN_CONCENTRATION="${OMIP_REICING_MIN_CONCENTRATION:-0.7}"
REICING_INTERVAL_DAYS="${OMIP_REICING_INTERVAL_DAYS:-5}"

KSKEW="${KSKEW:-$DEFAULT_KSKEW}"
KSYMM="${KSYMM:-${KSYMMETRIC:-$DEFAULT_KSYMM}}"
DT="${DT:-$DEFAULT_DT}"
DZ_TOP="${DZ_TOP:-$DEFAULT_DZ_TOP}"
BIHARMONIC="${BIHARMONIC:-$DEFAULT_BIHARMONIC}"

KSKEW_JULIA="$KSKEW"
[[ "$KSKEW" == "0" ]] && KSKEW_JULIA="nothing"
KSYMM_JULIA="$KSYMM"
[[ "$KSYMM" == "0" ]] && KSYMM_JULIA="nothing"

if [[ "$CLOUD_ARCH" == "cpu" ]]; then
  ARCH_EXPR="CPU()"
  EXTRA_USING=""
  FILE_SPLIT_KWARG=""
elif [[ "$CLOUD_ARCH" == "gpu" ]]; then
  ARCH_EXPR="$DEFAULT_ARCH"
  EXTRA_USING="$DEFAULT_EXTRA_USING"
  FILE_SPLIT_KWARG="$DEFAULT_FILE_SPLIT"
else
  echo "Unsupported CLOUD_ARCH=$CLOUD_ARCH" >&2
  exit 1
fi

RUN_NAME="$CONFIG"
[[ "${CORRECTED:-false}" == "true" ]]        && RUN_NAME="${RUN_NAME}_corrected"
[[ "${NCAR:-false}" == "true" ]]             && RUN_NAME="${RUN_NAME}_ncar"
[[ "${SNOW:-false}" == "true" ]]             && RUN_NAME="${RUN_NAME}_snow"
[[ "${ICE_DYNAMICS:-true}" == "false" ]]     && RUN_NAME="${RUN_NAME}_noicedyn"
[[ "${CLOSURE:-catke}" == "simple" ]]        && RUN_NAME="${RUN_NAME}_simple"
[[ "${CLOSURE:-catke}" == "nori" ]]          && RUN_NAME="${RUN_NAME}_nori"
[[ "${CLOSURE:-catke}" == "rbvd" ]]          && RUN_NAME="${RUN_NAME}_rbvd"
[[ "${CLOSURE:-catke}" == "kpp" ]]           && RUN_NAME="${RUN_NAME}_kpp"
[[ "${CLOSURE:-catke}" == "nemo_tke" ]]      && RUN_NAME="${RUN_NAME}_nemotke"
[[ "${WIND_VELOCITY:-false}" == "true" ]]    && RUN_NAME="${RUN_NAME}_wind"
[[ "${NORMALIZE_SALINITY:-false}" == "true" ]] && RUN_NAME="${RUN_NAME}_normsalt"
[[ -n "${CB:-}" ]]                           && RUN_NAME="${RUN_NAME}_cb${CB}"
[[ "$KSKEW" != "$DEFAULT_KSKEW" ]]           && RUN_NAME="${RUN_NAME}_kskew${KSKEW}"
[[ "$KSYMM" != "$DEFAULT_KSYMM" ]]           && RUN_NAME="${RUN_NAME}_ksymm${KSYMM}"
[[ "$BIHARMONIC" != "$DEFAULT_BIHARMONIC" ]] && RUN_NAME="${RUN_NAME}_bih${BIHARMONIC}"
[[ -n "${BIHVISC:-}" ]]                      && RUN_NAME="${RUN_NAME}_bihvisc${BIHVISC}"
[[ "$DZ_TOP" != "$DEFAULT_DZ_TOP" ]]         && RUN_NAME="${RUN_NAME}_dz${DZ_TOP}"
[[ "${SHEAR_GUST:-false}" == "true" ]]       && RUN_NAME="${RUN_NAME}_sgust"
[[ -n "${CATKE_CWUSTAR:-}" ]]                && RUN_NAME="${RUN_NAME}_cwu${CATKE_CWUSTAR}"
[[ -n "${MIN_SALINITY:-}" ]]                 && RUN_NAME="${RUN_NAME}_smin${MIN_SALINITY}"

mkdir -p "$OUTPUT_DIR" "$FORCING_DIR" "$RESTORING_DIR" "$OMIP_GLORYS_DIR"
if [[ -n "$STAGING_DIR" ]]; then
  mkdir -p "$STAGING_DIR"
fi

FLUX_KWARG=""
[[ "${NCAR:-false}" == "true" ]]      && FLUX_KWARG="flux_configuration = :ncar,"
[[ "${CORRECTED:-false}" == "true" ]] && FLUX_KWARG="flux_configuration = :corrected,"
[[ "${SHEAR_GUST:-false}" == "true" ]] && FLUX_KWARG="flux_configuration = :shear_aware,"

SNOW_KWARG=""
[[ "${SNOW:-false}" == "true" ]] && SNOW_KWARG="with_snow = true,"

ICE_DYNAMICS_KWARG=""
[[ "${ICE_DYNAMICS:-true}" == "false" ]] && ICE_DYNAMICS_KWARG="with_ice_dynamics = false,"

CB_KWARG=""
[[ -n "${CB:-}" ]] && CB_KWARG="Cᵇ = ${CB},"

BIHVISC_KWARG=""
[[ -n "${BIHVISC:-}" ]] && BIHVISC_KWARG="biharmonic_viscosity = ${BIHVISC},"

DZ_TOP_KWARG=""
[[ -n "$DZ_TOP" ]] && DZ_TOP_KWARG="Δz_top = ${DZ_TOP},"

CATKE_CWUSTAR_KWARG=""
[[ -n "${CATKE_CWUSTAR:-}" ]] && CATKE_CWUSTAR_KWARG="Cᵂu★ = ${CATKE_CWUSTAR},"

MIN_SALINITY_KWARG=""
[[ -n "${MIN_SALINITY:-}" ]] && MIN_SALINITY_KWARG="ocean_minimum_salinity = ${MIN_SALINITY},"

NORMALIZE_SALINITY_KWARG=""
[[ "${NORMALIZE_SALINITY:-false}" == "true" ]] && NORMALIZE_SALINITY_KWARG="normalize_salinity = true,"

BACKEND_KWARG=""
[[ -n "$BACKEND_SIZE" ]] && BACKEND_KWARG="backend_size = ${BACKEND_SIZE},"

CLOSURE_KWARG=""
[[ "${CLOSURE:-catke}" == "simple" ]]   && CLOSURE_KWARG="vertical_closure = :simple,"
[[ "${CLOSURE:-catke}" == "nori" ]]     && CLOSURE_KWARG="vertical_closure = :nori,"
[[ "${CLOSURE:-catke}" == "rbvd" ]]     && CLOSURE_KWARG="vertical_closure = :rbvd,"
[[ "${CLOSURE:-catke}" == "kpp" ]]      && CLOSURE_KWARG="vertical_closure = :kpp,"
[[ "${CLOSURE:-catke}" == "nemo_tke" ]] && CLOSURE_KWARG="vertical_closure = :nemo_tke,"

VELOCITY_KWARG=""
[[ "${WIND_VELOCITY:-false}" == "true" ]] && VELOCITY_KWARG="velocity_formulation = :wind,"

STAGING_KWARG=""
if [[ -n "$STAGING_DIR" ]]; then
  STAGING_KWARG="staging_dir = \"${STAGING_DIR}/${RUN_NAME}\","
fi

DIAGNOSTICS_KWARG="diagnostics = true,"
[[ "$DIAGNOSTICS" == "false" ]] && DIAGNOSTICS_KWARG="diagnostics = false,"
[[ "$PROFILE" == "true" ]] && DIAGNOSTICS_KWARG="diagnostics = false,"

RUN_CMD="${DEFAULT_STOP_CMD}"
if [[ -n "${STOP_ITERATION:-}" ]]; then
  RUN_CMD=$'sim.stop_iteration = '"${STOP_ITERATION}"$'\nrun!(sim)'
elif [[ -n "${STOP_TIME:-}" ]]; then
  RUN_CMD=$'sim.stop_time = '"${STOP_TIME}"$'\nrun!(sim)'
elif [[ "$PROFILE" == "true" ]]; then
  RUN_CMD=$'sim.stop_iteration = 200\nrun!(sim)'
fi

JULIA_EXPR="function cloud_stage(msg)
    println(msg)
    flush(stdout)
    flush(stderr)
    return nothing
end

ENV[\"DATADEPS_ALWAYS_ACCEPT\"] = \"true\"
cloud_stage(\"Stage: enabled noninteractive DataDeps\")

cloud_stage(\"Stage: using OMIPSimulations\")
using OMIPSimulations
cloud_stage(\"Stage: loaded OMIPSimulations\")
cloud_stage(\"Stage: using Oceananigans\")
using Oceananigans
cloud_stage(\"Stage: loaded Oceananigans\")
cloud_stage(\"Stage: using Oceananigans.Units\")
using Oceananigans.Units
cloud_stage(\"Stage: loaded Oceananigans.Units\")
cloud_stage(\"Stage: using Dates\")
using Dates
cloud_stage(\"Stage: loaded Dates\")
cloud_stage(\"Stage: using CUDA\")
using CUDA
cloud_stage(\"Stage: loaded CUDA\")
CUDA.precompile_runtime()
cloud_stage(\"Stage: CUDA runtime precompiled\")
${EXTRA_USING}
cloud_stage(\"Stage: including patch\")
include(\"${PATCH_PATH}\")
cloud_stage(\"Stage: included patch\")

function cloud_main()
    build_start_ns = time_ns()
    cloud_stage(\"Stage: invoking omip_simulation\")
    @info \"Building OMIP simulation\" config = :${CONFIG} arch = \"${CLOUD_ARCH}\" start_date = DateTime(\"${START_DATE}\") end_date = DateTime(\"${END_DATE}\")
    sim_kwargs = (
        arch = ${ARCH_EXPR},
        Nz = ${NZ},
        depth = 5500,
        Δz_top = ${DZ_TOP:-1.5},
        κ_skew = ${KSKEW_JULIA},
        κ_symmetric = ${KSYMM_JULIA},
        Cᵇ = ${CB:-0.28},
        biharmonic_timescale = ${BIHARMONIC},
        biharmonic_viscosity = ${BIHVISC:-nothing},
        forcing_dir = \"${FORCING_DIR}\",
        staging_dir = $( [[ -n "$STAGING_DIR" ]] && printf '"%s/%s"' "${STAGING_DIR}" "${RUN_NAME}" || printf 'nothing' ),
        backend_size = ${BACKEND_SIZE:-4},
        restoring_dir = \"${RESTORING_DIR}\",
        piston_velocity = 1 / 6,
        start_date = DateTime(\"${START_DATE}\"),
        end_date = DateTime(\"${END_DATE}\"),
        Δt = ${DT},
        stop_time = Inf,
        flux_configuration = $( [[ "${CORRECTED:-false}" == "true" ]] && printf ':corrected' || ([[ "${NCAR:-false}" == "true" ]] && printf ':ncar' || ([[ "${SHEAR_GUST:-false}" == "true" ]] && printf ':shear_aware' || printf ':default')) ),
        vertical_closure = $( [[ -n "${CLOSURE_KWARG}" ]] && printf ':%s' "${CLOSURE:-catke}" || printf ':catke' ),
        velocity_formulation = $( [[ "${WIND_VELOCITY:-false}" == "true" ]] && printf ':wind' || printf ':relative' ),
        Cᵂu★ = ${CATKE_CWUSTAR:-nothing},
        with_snow = $( [[ "${SNOW:-false}" == "true" ]] && printf 'true' || printf 'false' ),
        with_ice_dynamics = $( [[ "${ICE_DYNAMICS:-true}" == "false" ]] && printf 'false' || printf 'true' ),
        normalize_salinity = $( [[ "${NORMALIZE_SALINITY:-false}" == "true" ]] && printf 'true' || printf 'false' ),
        diagnostics = ${DIAGNOSTICS},
        field_mean_interval = 5days,
        surface_averaging_interval = 5days,
        field_averaging_interval = 15days,
        checkpoint_interval = 360days,
        output_dir = \"${OUTPUT_DIR}/${RUN_NAME}_run\",
        filename_prefix = \"${RUN_NAME}\",
        file_splitting_interval = ${FILE_SPLITTING_INTERVAL},
    )
    sim = Base.invokelatest(omip_simulation, :${CONFIG}; sim_kwargs...)
    cloud_stage(\"Stage: omip_simulation returned\")
    @info \"Built OMIP simulation\" elapsed_seconds = (time_ns() - build_start_ns) / 1e9

    if ${ARTIFICIAL_REICING}
        add_artificial_reicing_callback!(sim;
                                         lon_bounds = (${REICING_LON_MIN}, ${REICING_LON_MAX}),
                                         lat_bounds = (${REICING_LAT_MIN}, ${REICING_LAT_MAX}),
                                         increment = ${REICING_INCREMENT_M},
                                         concentration_threshold = ${REICING_MIN_CONCENTRATION},
                                         interval = ${REICING_INTERVAL_DAYS}days)
    end

    if ${DIAGNOSTICS}
        @info \"Configured output writers\" collect(keys(sim.output_writers))
        isempty(sim.output_writers) && error(\"Diagnostics requested but no output writers were attached.\")
    end

    run_start_ns = time_ns()
    @info \"Starting OMIP run\"
    ${RUN_CMD}
    @info \"Finished OMIP run\" elapsed_seconds = (time_ns() - run_start_ns) / 1e9 iteration = iteration(sim) model_time = sim.model.clock.time
end

cloud_main()"

echo "Launching NumericalEarth PR59 on cloud"
echo "  config=$CONFIG"
echo "  cloud_arch=$CLOUD_ARCH"
echo "  run_name=$RUN_NAME"
echo "  forcing_dir=$FORCING_DIR"
echo "  restoring_dir=$RESTORING_DIR"
echo "  glorys_dir=$OMIP_GLORYS_DIR"
echo "  output_dir=$OUTPUT_DIR/${RUN_NAME}_run"
echo "  artificial_reicing=$ARTIFICIAL_REICING"
echo "  orca_active_cells_map=$ORCA_ACTIVE_CELLS_MAP"
echo "  julia_optlevel=${JULIA_OPTLEVEL:-default}"
echo "  julia_compile_mode=${JULIA_COMPILE_MODE:-default}"
echo "  julia_pkgimages=${JULIA_PKGIMAGES:-default}"
echo "  julia_inline=${JULIA_INLINE:-default}"
echo "  julia_sysimage=${JULIA_SYSIMAGE:-default}"
if [[ "$ARTIFICIAL_REICING" == "true" ]]; then
  echo "  reicing_lon_bounds=[$REICING_LON_MIN, $REICING_LON_MAX]"
  echo "  reicing_lat_bounds=[$REICING_LAT_MIN, $REICING_LAT_MAX]"
  echo "  reicing_increment_m=$REICING_INCREMENT_M"
  echo "  reicing_min_concentration=$REICING_MIN_CONCENTRATION"
  echo "  reicing_interval_days=$REICING_INTERVAL_DAYS"
fi

JULIA_FLAGS=(--project="$PROJECT_DIR" --check-bounds=no -t "$THREADS")
[[ -n "$JULIA_OPTLEVEL" ]] && JULIA_FLAGS+=("-O${JULIA_OPTLEVEL}")

if [[ "$CLOUD_ARCH" == "gpu" && "${JULIA_COMPILE_MODE:-}" == "min" ]]; then
  echo "  overriding julia_compile_mode=min to yes for GPU llvmcall support"
  JULIA_COMPILE_MODE="yes"
fi

[[ -n "$JULIA_COMPILE_MODE" ]] && JULIA_FLAGS+=("--compile=${JULIA_COMPILE_MODE}")
[[ -n "$JULIA_COMPILED_MODULES" ]] && JULIA_FLAGS+=("--compiled-modules=${JULIA_COMPILED_MODULES}")
[[ -n "$JULIA_PKGIMAGES" ]] && JULIA_FLAGS+=("--pkgimages=${JULIA_PKGIMAGES}")
[[ -n "$JULIA_INLINE" ]] && JULIA_FLAGS+=("--inline=${JULIA_INLINE}")
[[ -n "$JULIA_SYSIMAGE" ]] && JULIA_FLAGS+=("-J" "$JULIA_SYSIMAGE")

JULIA_SCRIPT_PATH="${JULIA_SCRIPT_PATH:-${OUTPUT_DIR}/${RUN_NAME}_cloud_launch.jl}"
printf '%s\n' "$JULIA_EXPR" > "$JULIA_SCRIPT_PATH"

"$JULIA" "${JULIA_FLAGS[@]}" "$JULIA_SCRIPT_PATH"
