#!/usr/bin/env bash
set -euo pipefail

export JULIA="${JULIA:-/opt/Sea_ice/tools/julia-1.12.1/bin/julia}"
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-/opt/Sea_ice/clima/.julia_depot}"
export JULIA_PKG_PRECOMPILE_AUTO="${JULIA_PKG_PRECOMPILE_AUTO:-0}"
export DATADEPS_ALWAYS_ACCEPT="${DATADEPS_ALWAYS_ACCEPT:-true}"
export TMPDIR="${TMPDIR:-/opt/Sea_ice/tmp}"

PR_TARBALL_URL="${PR_TARBALL_URL:-https://codeload.github.com/NumericalEarth/NumericalEarth.jl/tar.gz/refs/pull/59/head}"
WORK_ROOT="${WORK_ROOT:-/opt/Sea_ice/experiments/numericalearth_pr59}"
TARBALL_PATH="${TARBALL_PATH:-$WORK_ROOT/numericalearth_pr59.tar.gz}"
SRC_ROOT="${SRC_ROOT:-$WORK_ROOT/NumericalEarth.jl-refs-pull-59-head}"
PROJECT_DIR="${PROJECT_DIR:-$SRC_ROOT/experiments/OMIPSimulations}"
PATCH_SCRIPT="${PATCH_SCRIPT:-/home/rafaelabel/numericalearth_pr59_ecco_init_patch.jl}"
LAUNCH_SCRIPT="${LAUNCH_SCRIPT:-/home/rafaelabel/numericalearth_pr59_launch_cloud.sh}"
RUN_NAME="${RUN_NAME:-numericalearth-pr59-omip-${OMIP_ARCH:-cpu}}"
OUTPUT_DIR="${OMIP_OUTPUT_DIR:-/home/rafaelabel/numericalearth_pr59_${OMIP_ARCH:-cpu}}"
DATA_ROOT="${DATA_ROOT:-/opt/Sea_ice/data/numericalearth_pr59}"
OMIP_FORCING_DIR="${OMIP_FORCING_DIR:-$DATA_ROOT/forcing_data}"
OMIP_RESTORING_DIR="${OMIP_RESTORING_DIR:-$DATA_ROOT/woa_climatology}"
OMIP_GLORYS_DIR="${OMIP_GLORYS_DIR:-$DATA_ROOT/glorys}"
OMIP_ECCO_DIR="${OMIP_ECCO_DIR:-$DATA_ROOT/ecco4}"
OMIP_BUCKET_NAME="${OMIP_BUCKET_NAME:-sea_ice}"
OMIP_GLORYS_BUCKET_PREFIX="${OMIP_GLORYS_BUCKET_PREFIX:-inputs/tripolar_glorys_jra55/2006/glorys}"
OMIP_ECCO_BUCKET_PREFIX="${OMIP_ECCO_BUCKET_PREFIX:-inputs/tripolar_ecco4/2006/ecco4}"
OMIP_JRA55_BUCKET_PREFIX="${OMIP_JRA55_BUCKET_PREFIX:-inputs/tripolar_glorys_jra55/2006/jra55}"
# January-2006 starts require four previous-year forcing records. These exact
# files are already staged in the project bucket; use them before attempting
# the much slower external ESGF fallback.
OMIP_JRA55_PREVIOUS_YEAR_BUCKET_PREFIX="${OMIP_JRA55_PREVIOUS_YEAR_BUCKET_PREFIX:-inputs/arctic_rotated_glorys12_jra55/2006-01-01_2007-01-01/2006-01-01/jra55}"
OMIP_UPLOAD_OUTPUTS="${OMIP_UPLOAD_OUTPUTS:-false}"
OMIP_OUTPUT_BUCKET_PREFIX="${OMIP_OUTPUT_BUCKET_PREFIX:-outputs/numericalearth_pr59}"
OMIP_SHUTDOWN_ON_EXIT="${OMIP_SHUTDOWN_ON_EXIT:-false}"
OMIP_SHUTDOWN_ON_FAILURE="${OMIP_SHUTDOWN_ON_FAILURE:-true}"
OMIP_LAUNCHER_LOG="${OMIP_LAUNCHER_LOG:-}"
OMIP_INIT_SOURCE="${OMIP_INIT_SOURCE:-glorys}"
OMIP_HYDRATE_FROM_BUCKET="${OMIP_HYDRATE_FROM_BUCKET:-true}"
OMIP_RESET_STAGING="${OMIP_RESET_STAGING:-true}"
OMIP_START_DATE="${OMIP_START_DATE:-2006-01-01T00:00:00}"
OMIP_END_DATE="${OMIP_END_DATE:-2006-12-31T00:00:00}"
SEA_ICE_THERMODYNAMICS="${OMIP_SEA_ICE_THERMODYNAMICS:-slab}"
if [[ "$SEA_ICE_THERMODYNAMICS" == "pr141" || "$SEA_ICE_THERMODYNAMICS" == "pr141_bl99" || "$SEA_ICE_THERMODYNAMICS" == "bl99" ]]; then
  DEFAULT_CLIMASEAICE_VARIANT="pr141_85e261e"
  DEFAULT_CLIMASEAICE_URL="https://codeload.github.com/CliMA/ClimaSeaIce.jl/tar.gz/85e261e46fdb935e3a492e5de7ae769911e72df4"
else
  # The upstream branch was transient. Pin the source used by the successful
  # old-thermodynamics run in this fork so VM hydration remains reproducible.
  DEFAULT_CLIMASEAICE_VARIANT="pr59_old_thermo_d6b9bbc"
  DEFAULT_CLIMASEAICE_URL="https://codeload.github.com/RafaelAbel/ClimaSeaIce.jl/tar.gz/d6b9bbc32867eea61008b3b8c5ac5faaa9adf416"
fi
CLIMASEAICE_VARIANT="${CLIMASEAICE_VARIANT:-$DEFAULT_CLIMASEAICE_VARIANT}"
CLIMASEAICE_URL="${CLIMASEAICE_URL:-$DEFAULT_CLIMASEAICE_URL}"
CLIMASEAICE_TARBALL="${CLIMASEAICE_TARBALL:-$WORK_ROOT/climaseaice_${CLIMASEAICE_VARIANT}.tar.gz}"
CLIMASEAICE_SRC="${CLIMASEAICE_SRC:-$WORK_ROOT/ClimaSeaIce.jl-${CLIMASEAICE_VARIANT}}"
OCEANANIGANS_TARBALL="${OCEANANIGANS_TARBALL:-}"
OCEANANIGANS_SRC="${OCEANANIGANS_SRC:-}"
CLIMAOCEAN_PROJECT="${CLIMAOCEAN_PROJECT:-/opt/Sea_ice/clima/ClimaOcean.jl-main}"
INSTANTIATE_STAMP="${INSTANTIATE_STAMP:-$WORK_ROOT/.omip_project_instantiated_${CLIMASEAICE_VARIANT}_v1}"
RUNNER_LOCK_PATH="${RUNNER_LOCK_PATH:-$WORK_ROOT/.omip_runner.lock}"
REFRESH_PR_SOURCE="${REFRESH_PR_SOURCE:-false}"
# PR141's eight-layer implementation was developed against the June 8 PR59
# source snapshot and its Oceananigans 0.108.1 revision. Keep that exact
# source/dependency family intact: the generic 0.108.0 release lacks the
# baseline's adaptive vertical-advection support.
OMIP_CLEAN_PR59_BASELINE="${OMIP_CLEAN_PR59_BASELINE:-false}"

mkdir -p "$WORK_ROOT"

RUNNER_OWNS_LOCK=false
exec 9>"$RUNNER_LOCK_PATH"
if ! flock -n 9; then
  echo "Another OMIP launcher is already active on this VM (lock: $RUNNER_LOCK_PATH)." >&2
  exit 99
fi
RUNNER_OWNS_LOCK=true

mkdir -p "$OUTPUT_DIR" "$OMIP_FORCING_DIR" "$OMIP_RESTORING_DIR" "$OMIP_GLORYS_DIR" "$OMIP_ECCO_DIR"

if [[ ! -f "$LAUNCH_SCRIPT" ]]; then
  echo "Launch script not found: $LAUNCH_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$PATCH_SCRIPT" ]]; then
  echo "Patch script not found: $PATCH_SCRIPT" >&2
  exit 1
fi

patch_project_tomls() {
  local needs_pr141=false
  if [[ "$SEA_ICE_THERMODYNAMICS" == "pr141" || "$SEA_ICE_THERMODYNAMICS" == "pr141_bl99" || "$SEA_ICE_THERMODYNAMICS" == "bl99" ]]; then
    needs_pr141=true
  fi

  hydrate_climaseaice_source() {
    local unpack_dir extracted_dir
    mkdir -p "$WORK_ROOT"
    unpack_dir="$(mktemp -d "$WORK_ROOT/climaseaice_unpack.XXXXXX")"
    tar -xzf "$CLIMASEAICE_TARBALL" -C "$unpack_dir"
    extracted_dir="$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -z "$extracted_dir" ]]; then
      echo "Failed to find extracted ClimaSeaIce source in $CLIMASEAICE_TARBALL" >&2
      rm -rf "$unpack_dir"
      exit 1
    fi
    rm -rf "$CLIMASEAICE_SRC"
    mv "$extracted_dir" "$CLIMASEAICE_SRC"
    rm -rf "$unpack_dir"
  }

  source_matches_requested_thermodynamics() {
    [[ -d "$CLIMASEAICE_SRC" ]] || return 1

    if [[ "$needs_pr141" == "true" ]]; then
      grep -q 'FixedSalinityBrinePocketEnergyRelation' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl"
    else
      return 0
    fi
  }

  if ! source_matches_requested_thermodynamics; then
    if [[ ! -f "$CLIMASEAICE_TARBALL" ]]; then
      curl -L "$CLIMASEAICE_URL" -o "$CLIMASEAICE_TARBALL"
    fi
    hydrate_climaseaice_source
  fi

  sed -i 's/^version = "0.5.1"$/version = "0.5.7"/' "$CLIMASEAICE_SRC/Project.toml"
  sed -i 's/^version = "0.5.5"$/version = "0.5.7"/' "$CLIMASEAICE_SRC/Project.toml"
  sed -i 's/^Oceananigans = "0.106, 0.107, 0.108"$/Oceananigans = "0.106, 0.107, 0.108, 0.110, 0.111"/' \
    "$CLIMASEAICE_SRC/Project.toml"
  sed -i 's/^Oceananigans = "0.106, 0.107, =0.108, 0.109.1"$/Oceananigans = "0.106, 0.107, =0.108, 0.109.1, 0.110"/' \
    "$CLIMASEAICE_SRC/Project.toml"
  sed -i '/^__precompile__(false)$/d' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl"
  sed -i '1i __precompile__(false)' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl"
  # Retain the SeaIceModel-level fallback: it is required when PR141 runs
  # without ice dynamics. Remove the duplicate internal-thermodynamics
  # definition instead, which avoids the Julia 1.12 duplicate-method issue.
  sed -i '/^fields(::Nothing) = NamedTuple()$/d' "$CLIMASEAICE_SRC/src/SeaIceThermodynamics/nothing_thermodynamics.jl"

  sed -i 's/^ClimaSeaIce = "0.5.7, 0.6"$/ClimaSeaIce = "0.5, 0.6"/' "$SRC_ROOT/Project.toml"
  sed -i 's/^ClimaSeaIce = "0.5.5"$/ClimaSeaIce = "0.5, 0.6"/' "$SRC_ROOT/Project.toml"
  sed -i 's/^ClimaSeaIce = "0.5"$/ClimaSeaIce = "0.5, 0.6"/' "$PROJECT_DIR/Project.toml"
  sed -i 's/^Oceananigans = "0.108"$/Oceananigans = "0.108, 0.110, 0.111"/' "$SRC_ROOT/Project.toml"
  sed -i 's/^Oceananigans = "0.106.5, 0.107, 0.108"$/Oceananigans = "0.106.5, 0.107, 0.108, 0.110, 0.111"/' "$PROJECT_DIR/Project.toml"

  sed -i '/^ClimaSeaIce = {path = ".*"}$/d' "$SRC_ROOT/Project.toml"
  sed -i '/^ClimaSeaIce = {path = ".*"}$/d' "$PROJECT_DIR/Project.toml"

  sed -i "s|^ClimaSeaIce = {rev = \"ss/volume-conserving-advection\", url = \"https://github.com/CliMA/ClimaSeaIce.jl.git\"}|ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}|" \
    "$SRC_ROOT/Project.toml"

  sed -i "s|^ClimaSeaIce = {rev = \"ss/correct-bugs\", url = \"https://github.com/CliMA/ClimaSeaIce.jl.git\"}|ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}|" \
    "$SRC_ROOT/Project.toml"

  sed -i "s|^ClimaSeaIce = {rev = \"ss/volume-conserving-advection\", url = \"https://github.com/CliMA/ClimaSeaIce.jl.git\"}|ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}|" \
    "$PROJECT_DIR/Project.toml"

  if ! grep -q '^ClimaSeaIce = {path = "' "$SRC_ROOT/Project.toml"; then
    sed -i "/^\[sources\]/a\\
ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}
" "$SRC_ROOT/Project.toml"
  fi

  if ! grep -q '^ClimaSeaIce = {path = "' "$PROJECT_DIR/Project.toml"; then
    sed -i "/^\[sources\]/a\\
ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}
" "$PROJECT_DIR/Project.toml"
  fi

  # These packages are only used by scripts/visualize and make VM bootstrap much slower.
  sed -i '/^ConservativeRegridding = /d' "$PROJECT_DIR/Project.toml"
  sed -i '/^GeoMakie = /d' "$PROJECT_DIR/Project.toml"
  sed -i '/^Glob = /d' "$PROJECT_DIR/Project.toml"

}

patch_numericalearth_api_compat() {
  local oceans_file="$SRC_ROOT/src/Oceans/Oceans.jl"
  local ocean_simulation_file="$SRC_ROOT/src/Oceans/ocean_simulation.jl"
  local atmosphere_file="$PROJECT_DIR/src/atmosphere.jl"
  local kpp_file="$PROJECT_DIR/src/KPP/kpp_vertical_diffusivity.jl"
  local nemo_tke_file="$PROJECT_DIR/src/NEMOTKE/nemo_tke_vertical_diffusivity.jl"

  perl -0pi -e 's/using Oceananigans\.BoundaryConditions: DefaultBoundaryCondition, DiscreteBoundaryFunction,\n\s+FieldBoundaryConditions, FluxBoundaryCondition,\n\s+ImplicitExplicitFluxBoundaryCondition, ImplicitExplicitFlux, getbc/using Oceananigans.BoundaryConditions: DefaultBoundaryCondition, DiscreteBoundaryFunction,\n                                       FieldBoundaryConditions, FluxBoundaryCondition,\n                                       getbc/s' "$oceans_file"

  # The archived source converts conservative temperature to potential
  # temperature solely for the atmosphere-exchange field. Its pinned
  # SeawaterPolynomials revision no longer provides that legacy helper. The
  # prognostic ocean tracer is already conservative temperature, so retain it
  # directly rather than compiling a call to a nonexistent GPU function.
  perl -0pi -e 's/, θᴾ_from_Θ//' "$oceans_file"
  perl -0pi -e 's/θᴾ_from_Θ\(Sᵒᶜ\[i, j, kᴺ\], Tᵒᶜ\[i, j, kᴺ\]\)/Tᵒᶜ[i, j, kᴺ]/g' "$oceans_file"

  perl -0pi -e 's/\@inline net_flux\(condition\) = condition\n\@inline net_flux\(bc::MultipleFluxes\) = bc\.flux_field\n\@inline net_flux\(bc::DiscreteBoundaryFunction\) = net_flux\(bc\.func\)\n\@inline net_flux\(bc::[^\n]+\) = net_flux\(bc\.explicit_flux\)\n\n\@inline net_flux_coefficient\(condition\) = nothing\n\@inline net_flux_coefficient\(bc::[^\n]+\) = net_flux\(bc\.coefficient\)/\@inline net_flux(condition) = hasproperty(condition, :explicit_flux) ? net_flux(getproperty(condition, :explicit_flux)) : condition\n\@inline net_flux(bc::MultipleFluxes) = bc.flux_field\n\@inline net_flux(bc::DiscreteBoundaryFunction) = net_flux(bc.func)\n\n\@inline net_flux_coefficient(condition) = hasproperty(condition, :coefficient) ? net_flux(getproperty(condition, :coefficient)) : nothing/s' "$oceans_file"

  perl -0pi -e 's/ImplicitExplicitFluxBoundaryCondition\(/Oceananigans.BoundaryConditions.ImplicitExplicitFluxBoundaryCondition(/g' "$ocean_simulation_file"

  # PR141 BL99 uses a vertical temperature column, while the archived JRA55
  # albedo constructor expects a slab's 2-D `top_surface_temperature` field.
  # Keep its existing snow/slab handling and use the PR141 top-layer view only
  # when the old property is genuinely absent.
  perl -0pi -e 's/Ts = isnothing\(snow_thermo\) \? sea_ice\.model\.ice_thermodynamics\.top_surface_temperature :\n\s*snow_thermo\.top_surface_temperature/ice_thermo = sea_ice.model.ice_thermodynamics\n    Ts = isnothing(snow_thermo) ?\n         (hasproperty(ice_thermo, :top_surface_temperature) ? ice_thermo.top_surface_temperature : Main.PR141TopLayerTemperature(ice_thermo.fields.temperature)) :\n         snow_thermo.top_surface_temperature/' "$atmosphere_file"

  # Oceananigans 0.108 predates the semi-implicit momentum-flux boundary
  # condition used by the archived NumericalEarth source. Supply the small
  # representation adapter before the Oceans module closes. The explicit
  # component remains the normal flux boundary condition; the coefficient is
  # preserved on the condition for the old source's flux bookkeeping.
  cat > "$SRC_ROOT/src/Oceans/implicit_flux_compat.jl" <<'JULIA'
if !isdefined(Oceananigans.BoundaryConditions, :ImplicitExplicitFluxBoundaryCondition)
    @eval Oceananigans.BoundaryConditions begin
        using ..Architectures: on_architecture

        struct CompatImplicitExplicitFlux{E, C}
            explicit_flux :: E
            coefficient   :: C
        end

        Adapt.adapt_structure(to, c::CompatImplicitExplicitFlux) =
            CompatImplicitExplicitFlux(Adapt.adapt(to, c.explicit_flux), Adapt.adapt(to, c.coefficient))

        on_architecture(to, c::CompatImplicitExplicitFlux) =
            CompatImplicitExplicitFlux(on_architecture(to, c.explicit_flux),
                                       on_architecture(to, c.coefficient))

        function ImplicitExplicitFluxBoundaryCondition(explicit_flux; coefficient,
                                                       parameters = nothing,
                                                       discrete_form = false,
                                                       field_dependencies = ())
            Fₑ = materialize_condition(explicit_flux, parameters, discrete_form, field_dependencies)
            λ  = materialize_condition(coefficient, parameters, discrete_form, field_dependencies)
            return BoundaryCondition(Flux(), CompatImplicitExplicitFlux(Fₑ, λ))
        end

        @inline getbc(condition::CompatImplicitExplicitFlux, args...) =
            getbc(condition.explicit_flux, args...)
    end
end
JULIA
  sed -i '/^include("implicit_flux_compat.jl")$/d' "$oceans_file"
  sed -i '/^end # module$/i include("implicit_flux_compat.jl")' "$oceans_file"

  # Oceananigans 0.108 owns this closure trait in TurbulenceClosures, not
  # TimeSteppers. The archived KPP and NEMO-TKE implementations predate that
  # namespace move. Both modules are always loaded by OMIPSimulations.
  for closure_file in "$kpp_file" "$nemo_tke_file"; do
    [[ -f "$closure_file" ]] || continue
    sed -i 's/TimeSteppers\.time_discretization/Oceananigans.TurbulenceClosures.time_discretization/g' "$closure_file"
  done
}

wire_clean_pr141_source() {
  # This is deliberately the only project mutation in the clean PR141 path:
  # direct the two project environments to the packaged PR141 source. The
  # baseline's own NumericalEarth, Oceananigans, and forcing code remain as
  # they were in the June 8 source snapshot.
  local project

  if [[ ! -d "$CLIMASEAICE_SRC" ]]; then
    local unpack_dir extracted_dir
    [[ -f "$CLIMASEAICE_TARBALL" ]] || {
      echo "Missing packaged PR141 ClimaSeaIce source: $CLIMASEAICE_TARBALL" >&2
      exit 1
    }
    unpack_dir="$(mktemp -d "$WORK_ROOT/climaseaice_unpack.XXXXXX")"
    tar -xzf "$CLIMASEAICE_TARBALL" -C "$unpack_dir"
    extracted_dir="$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$extracted_dir" ]] || {
      echo "Failed to find extracted PR141 source in $CLIMASEAICE_TARBALL" >&2
      exit 1
    }
    mv "$extracted_dir" "$CLIMASEAICE_SRC"
    rm -rf "$unpack_dir"
  fi

  grep -q 'FixedSalinityBrinePocketEnergyRelation' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl" || {
    echo "Packaged ClimaSeaIce source is not the PR141 thermodynamics revision." >&2
    exit 1
  }

  [[ -n "$OCEANANIGANS_TARBALL" && -n "$OCEANANIGANS_SRC" ]] || {
    echo "The clean PR141 baseline requires its pinned Oceananigans source." >&2
    exit 1
  }
  [[ -f "$OCEANANIGANS_TARBALL" ]] || {
    echo "Missing pinned Oceananigans archive: $OCEANANIGANS_TARBALL" >&2
    exit 1
  }

  # The known-good June 8 run used Oceananigans 0.108.1 at a local path.
  # Validate the capability rather than trusting a cache that may have been
  # populated by a prior generic 0.108.0 attempt.
  if [[ ! -f "$OCEANANIGANS_SRC/Project.toml" ]] || \
     ! grep -q '^version = "0.108.1"$' "$OCEANANIGANS_SRC/Project.toml" || \
     ! grep -q 'AdaptiveVerticallyImplicitDiscretization' "$OCEANANIGANS_SRC/src/TimeSteppers/time_discretization.jl"; then
    local unpack_dir extracted_dir
    unpack_dir="$(mktemp -d "$WORK_ROOT/oceananigans_unpack.XXXXXX")"
    tar -xzf "$OCEANANIGANS_TARBALL" -C "$unpack_dir"
    extracted_dir="$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$extracted_dir" ]] || {
      echo "Failed to find extracted Oceananigans source in $OCEANANIGANS_TARBALL" >&2
      rm -rf "$unpack_dir"
      exit 1
    }
    rm -rf "$OCEANANIGANS_SRC"
    mv "$extracted_dir" "$OCEANANIGANS_SRC"
    rm -rf "$unpack_dir"
  fi

  # The snapshot's OMIP project accepts the verified 0.108.1 source revision;
  # retain that compatibility family with the pinned local dependency.
  sed -i 's/^Oceananigans = "0.109"$/Oceananigans = "0.108"/' "$SRC_ROOT/Project.toml"
  sed -i 's/^version = "0.5.1"$/version = "0.5.7"/' "$CLIMASEAICE_SRC/Project.toml"
  sed -i 's/^SeawaterPolynomials = "0.4"$/SeawaterPolynomials = "0.3, 0.4"/' \
    "$PROJECT_DIR/Project.toml"
  # `=0.108` means exactly 0.108.0 in Julia's compatibility syntax. The
  # verified June source is 0.108.1, so allow the 0.108 patch series while
  # retaining the frozen dependency family.
  sed -i 's/^Oceananigans = "0.106, 0.107, =0.108, 0.109.1"$/Oceananigans = "0.106, 0.107, 0.108, 0.109.1"/' \
    "$CLIMASEAICE_SRC/Project.toml"

  # PR141 contains a duplicate `fields(::Nothing)` method in an internal
  # thermodynamics file. Keep the SeaIceModel fallback (needed for
  # `dynamics = nothing`) and remove only the duplicate; incremental
  # precompilation is disabled for this historical source on Julia 1.12.
  sed -i '/^__precompile__(false)$/d' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl"
  sed -i '1i __precompile__(false)' "$CLIMASEAICE_SRC/src/ClimaSeaIce.jl"
  sed -i '/^fields(::Nothing) = NamedTuple()$/d' "$CLIMASEAICE_SRC/src/SeaIceThermodynamics/nothing_thermodynamics.jl"

  for project in "$SRC_ROOT/Project.toml" "$PROJECT_DIR/Project.toml"; do
    sed -i '/^ClimaSeaIce = {path = ".*"}$/d' "$project"
    sed -i '/^Oceananigans = {path = ".*"}$/d' "$project"
    sed -i '/^Oceananigans = {rev = "ss\/for-omip", url = "https:\/\/github.com\/CliMA\/Oceananigans.jl.git"}$/d' "$project"
    sed -i '/^SeawaterPolynomials = {rev = "ss\/conversion-functions", url = "https:\/\/github.com\/CliMA\/SeawaterPolynomials.jl.git"}$/d' "$project"
    sed -i 's|^ClimaSeaIce = {rev = "ss/correct-bugs", url = "https://github.com/CliMA/ClimaSeaIce.jl.git"}|ClimaSeaIce = {path = "'"$CLIMASEAICE_SRC"'"}|' "$project"
    sed -i 's|^ClimaSeaIce = {rev = "ss/volume-conserving-advection", url = "https://github.com/CliMA/ClimaSeaIce.jl.git"}|ClimaSeaIce = {path = "'"$CLIMASEAICE_SRC"'"}|' "$project"
    if ! grep -q '^ClimaSeaIce = {path = "' "$project"; then
      sed -i "/^\[sources\]/a\\
ClimaSeaIce = {path = \"$CLIMASEAICE_SRC\"}
" "$project"
    fi
    if ! grep -q '^Oceananigans = {path = "' "$project"; then
      sed -i "/^\[sources\]/a\\
Oceananigans = {path = \"$OCEANANIGANS_SRC\"}
" "$project"
    fi
  done
}

required_glorys_files=(
  "$OMIP_GLORYS_DIR/thetao_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
  "$OMIP_GLORYS_DIR/so_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
  "$OMIP_GLORYS_DIR/uo_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
  "$OMIP_GLORYS_DIR/vo_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
  "$OMIP_GLORYS_DIR/sithick_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
  "$OMIP_GLORYS_DIR/siconc_GLORYSMonthly_2006-01-01T00-00-00_2006-01-01T00-00-00.nc"
)

required_ecco_files=(
  "$OMIP_ECCO_DIR/THETA_2006_01.nc"
  "$OMIP_ECCO_DIR/SALT_2006_01.nc"
  "$OMIP_ECCO_DIR/EVEL_2006_01.nc"
  "$OMIP_ECCO_DIR/NVEL_2006_01.nc"
  "$OMIP_ECCO_DIR/SIheff_2006_01.nc"
  "$OMIP_ECCO_DIR/SIarea_2006_01.nc"
)

required_ecco_specs=(
  "$OMIP_ECCO_DIR/THETA_2006_01.nc:103717993"
  "$OMIP_ECCO_DIR/SALT_2006_01.nc:103717966"
  "$OMIP_ECCO_DIR/EVEL_2006_01.nc:103718003"
  "$OMIP_ECCO_DIR/NVEL_2006_01.nc:103718005"
  "$OMIP_ECCO_DIR/SIheff_2006_01.nc:2110190"
  "$OMIP_ECCO_DIR/SIarea_2006_01.nc:2110183"
)

required_jra55_specs=(
  "$OMIP_FORCING_DIR/huss_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010000-200612312100.nc:1693779895"
  "$OMIP_FORCING_DIR/prra_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010130-200612312230.nc:1276573362"
  "$OMIP_FORCING_DIR/prsn_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010130-200612312230.nc:536351559"
  "$OMIP_FORCING_DIR/psl_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010000-200612312100.nc:1203778151"
  "$OMIP_FORCING_DIR/rlds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010130-200612312230.nc:1585683321"
  "$OMIP_FORCING_DIR/rsds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010130-200612312230.nc:1091890889"
  "$OMIP_FORCING_DIR/tas_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010000-200612312100.nc:1216625808"
  "$OMIP_FORCING_DIR/uas_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010000-200612312100.nc:1870104387"
  "$OMIP_FORCING_DIR/vas_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_200601010000-200612312100.nc:1888258184"
)

jra55_boundary_urls() {
  local prev_year="$1"
  local base_url="http://esgf-node.ornl.gov/thredds/fileServer/user_pub_work/input4MIPs/CMIP6/OMIP/MRI/MRI-JRA55-do-1-5-0/atmos/3hr"
  cat <<EOF
$OMIP_FORCING_DIR/prra_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc|$base_url/prra/gr/v20200916/prra_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc
$OMIP_FORCING_DIR/prsn_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc|$base_url/prsn/gr/v20200916/prsn_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc
$OMIP_FORCING_DIR/rlds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc|$base_url/rlds/gr/v20200916/rlds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc
$OMIP_FORCING_DIR/rsds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc|$base_url/rsds/gr/v20200916/rsds_input4MIPs_atmosphericState_OMIP_MRI-JRA55-do-1-5-0_gr_${prev_year}01010130-${prev_year}12312230.nc
EOF
}

needs_previous_year_jra55_boundary_files() {
  local start_md="${OMIP_START_DATE:5:5}"
  local start_hm="${OMIP_START_DATE:11:5}"
  [[ "$start_md" == "01-01" && "$start_hm" < "01:30" ]]
}

ensure_previous_year_jra55_boundary_files() {
  local start_year prev_year pair path url expected_size actual_size
  start_year=$((10#${OMIP_START_DATE:0:4}))
  prev_year=$((start_year - 1))

  local boundary_paths=()
  while IFS='|' read -r path url; do
    [[ -n "$path" ]] && boundary_paths+=("$path")
  done < <(jra55_boundary_urls "$prev_year")

  local missing_boundary=false
  for path in "${boundary_paths[@]}"; do
    [[ -f "$path" ]] || missing_boundary=true
  done

  if [[ "$missing_boundary" == "true" && -n "$OMIP_JRA55_PREVIOUS_YEAR_BUCKET_PREFIX" ]]; then
    echo "Staging previous-year JRA55 boundary files from the bucket"
    for path in "${boundary_paths[@]}"; do
      gcloud --project="${GOOGLE_CLOUD_PROJECT:-rafael-sandbox-488511}" storage cp \
        "gs://${OMIP_BUCKET_NAME}/${OMIP_JRA55_PREVIOUS_YEAR_BUCKET_PREFIX}/$(basename "$path")" \
        "$path"
    done
    return
  fi

  while IFS='|' read -r path url; do
    [[ -n "$path" ]] || continue
    expected_size="$(curl -fsIL "$url" | tr -d '\r' | awk 'tolower($1) == "content-length:" { print $2 }' | tail -n 1)"
    actual_size=0
    if [[ -f "$path" ]]; then
      actual_size="$(stat -c%s "$path")"
    fi

    if [[ -n "$expected_size" && "$actual_size" == "$expected_size" ]]; then
      continue
    fi

    if [[ "$actual_size" -gt 0 && -n "$expected_size" && "$actual_size" -lt "$expected_size" ]]; then
      echo "Resuming partial JRA55 boundary file $(basename "$path") ($actual_size / $expected_size bytes)"
      curl -fL --retry 5 --retry-delay 5 -C - "$url" -o "$path"
      continue
    fi

    if [[ "$actual_size" -gt 0 ]]; then
      echo "Refreshing incomplete JRA55 boundary file $(basename "$path")"
    else
      echo "Downloading JRA55 boundary file $(basename "$path")"
    fi
    rm -f "$path"
    curl -fL --retry 5 --retry-delay 5 "$url" -o "$path"
  done < <(jra55_boundary_urls "$prev_year")
}

all_files_exist() {
  local filepath
  for filepath in "$@"; do
    [[ -f "$filepath" ]] || return 1
  done
  return 0
}

all_specs_match() {
  local spec filepath expected_size actual_size
  for spec in "$@"; do
    filepath="${spec%%:*}"
    expected_size="${spec##*:}"
    [[ -f "$filepath" ]] || return 1
    actual_size="$(stat -c%s "$filepath")"
    [[ "$actual_size" == "$expected_size" ]] || return 1
  done
  return 0
}

download_bucket_glob() {
  local bucket="$1"
  local prefix="$2"
  local dest="$3"
  gcloud --project="${GOOGLE_CLOUD_PROJECT:-rafael-sandbox-488511}" storage cp "gs://${bucket}/${prefix}/*" "$dest/"
}

if [[ "$OMIP_HYDRATE_FROM_BUCKET" == "true" ]]; then
  if [[ "$OMIP_INIT_SOURCE" == "glorys" ]]; then
    all_files_exist "${required_glorys_files[@]}" || download_bucket_glob \
      "$OMIP_BUCKET_NAME" \
      "$OMIP_GLORYS_BUCKET_PREFIX" \
      "$OMIP_GLORYS_DIR"
  elif [[ "$OMIP_INIT_SOURCE" == "ecco" ]]; then
    all_specs_match "${required_ecco_specs[@]}" || download_bucket_glob \
      "$OMIP_BUCKET_NAME" \
      "$OMIP_ECCO_BUCKET_PREFIX" \
      "$OMIP_ECCO_DIR"
  else
    echo "Unsupported OMIP_INIT_SOURCE=$OMIP_INIT_SOURCE (use 'glorys' or 'ecco')." >&2
    exit 1
  fi

  all_specs_match "${required_jra55_specs[@]}" || download_bucket_glob \
    "$OMIP_BUCKET_NAME" \
    "$OMIP_JRA55_BUCKET_PREFIX" \
    "$OMIP_FORCING_DIR"
fi

if needs_previous_year_jra55_boundary_files; then
  ensure_previous_year_jra55_boundary_files
fi

case "$OMIP_INIT_SOURCE" in
  glorys)
    for filepath in "${required_glorys_files[@]}"; do
      if [[ ! -f "$filepath" ]]; then
        echo "Missing required GLORYS initialization file: $filepath" >&2
        exit 1
      fi
    done
    ;;
  ecco)
    for spec in "${required_ecco_specs[@]}"; do
      filepath="${spec%%:*}"
      expected_size="${spec##*:}"
      if [[ ! -f "$filepath" ]]; then
        echo "Missing required ECCO initialization file: $filepath" >&2
        exit 1
      fi
      if [[ "$(stat -c%s "$filepath")" != "$expected_size" ]]; then
        echo "ECCO initialization file has unexpected size: $filepath" >&2
        exit 1
      fi
    done
    ;;
esac

if [[ "$REFRESH_PR_SOURCE" == "true" ]]; then
  rm -rf "$SRC_ROOT"
fi

if [[ ! -d "$SRC_ROOT" ]]; then
  if [[ ! -f "$TARBALL_PATH" ]]; then
    curl -L "$PR_TARBALL_URL" -o "$TARBALL_PATH"
  fi
  tar -xzf "$TARBALL_PATH" -C "$WORK_ROOT"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "OMIP project directory not found: $PROJECT_DIR" >&2
  exit 1
fi

if [[ "$OMIP_CLEAN_PR59_BASELINE" == "true" ]]; then
  wire_clean_pr141_source
  # The archived pre–June 8 NumericalEarth sources import the old
  # `ImplicitExplicitFlux` binding, which is absent from the preserved
  # Oceananigans 0.108 release. This small source-level shim is required to
  # load that otherwise pinned baseline; it does not alter its ORCA setup or
  # sea-ice physics.
  patch_numericalearth_api_compat
else
  patch_project_tomls
  patch_numericalearth_api_compat

  # The moving PR59 tarball ships a locked OMIP manifest that pulls in a much
  # larger dependency graph than this legacy cloud smoke-test path needs.
  if [[ -f "$PROJECT_DIR/Manifest.toml" && ! -f "$PROJECT_DIR/Manifest.toml.pr59_backup" ]]; then
    mv "$PROJECT_DIR/Manifest.toml" "$PROJECT_DIR/Manifest.toml.pr59_backup"
  fi
fi

if [[ ! -f "$INSTANTIATE_STAMP" || ! -f "$PROJECT_DIR/Manifest.toml" ]]; then
  "$JULIA" --project="$PROJECT_DIR" -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'
  [[ -f "$PROJECT_DIR/Manifest.toml" ]] || {
    echo "Pkg.instantiate() did not produce $PROJECT_DIR/Manifest.toml." >&2
    exit 1
  }
  touch "$INSTANTIATE_STAMP"
fi

# Pkg can precompile CUDA's runtime-discovery JLL before the GPU driver is
# usable (notably just after a VM has booted). Rebuild and validate that cache
# only after staging is complete, before the long coupled launch. This turns a
# misleading later "a CUDA GPU was not found" error into an immediate, useful
# failure and keeps all GPU milestones on the same reliable startup path.
if [[ "${OMIP_ARCH:-cpu}" == "gpu" ]]; then
  # The frozen 2026 dependency family resolves CUDA_Runtime_jll 0.23, whose
  # packaged runtime is CUDA 13.3. Persist that choice before any downstream
  # package is precompiled; auto-discovery can otherwise cache a no-driver
  # platform during VM startup. A new Julia process is required after setting
  # this preference.
  "$JULIA" --project="$PROJECT_DIR" -e '
      using CUDA
      CUDA.set_runtime_version!(v"13.3")
      println("CUDA runtime preference set to 13.3")
  '
  "$JULIA" --project="$PROJECT_DIR" -e '
      using CUDA
      CUDA.precompile_runtime()
      CUDA.functional() || error("CUDA is not functional after runtime precompilation")
      println("CUDA runtime verified: ", only(CUDA.devices()))
  '
fi

export OMIP_FORCING_DIR
export OMIP_RESTORING_DIR
export OMIP_GLORYS_DIR
export OMIP_ECCO_DIR
export OMIP_OUTPUT_DIR="$OUTPUT_DIR"
export OMIP_CONFIG="${OMIP_CONFIG:-orca}"
export OMIP_DT="${OMIP_DT:-30minutes}"
export OMIP_STOP_TIME="${OMIP_STOP_TIME:-1day}"
export OMIP_STOP_ITERATION="${OMIP_STOP_ITERATION-}"
export OMIP_DIAGNOSTICS="${OMIP_DIAGNOSTICS:-true}"
export OMIP_WITH_SNOW="${OMIP_WITH_SNOW:-false}"
export OMIP_WITH_ICE_DYNAMICS="${OMIP_WITH_ICE_DYNAMICS:-true}"
export OMIP_NORMALIZE_SALINITY="${OMIP_NORMALIZE_SALINITY:-false}"
export OMIP_BACKEND_SIZE="${OMIP_BACKEND_SIZE:-4}"
export OMIP_FILENAME_PREFIX="${OMIP_FILENAME_PREFIX:-pr59_${OMIP_CONFIG}_${OMIP_ARCH:-cpu}_smoke}"
export PROJECT_DIR
export PATCH_PATH="$PATCH_SCRIPT"
export FORCING_DIR="$OMIP_FORCING_DIR"
export RESTORING_DIR="$OMIP_RESTORING_DIR"
export OUTPUT_DIR
export CLOUD_ARCH="${OMIP_ARCH:-cpu}"
export DIAGNOSTICS="${OMIP_DIAGNOSTICS:-true}"
export STOP_ITERATION="${OMIP_STOP_ITERATION-}"
export STOP_TIME="${OMIP_STOP_TIME:-1day}"
export DT="${OMIP_DT:-30minutes}"
export BACKEND_SIZE="${OMIP_BACKEND_SIZE:-4}"
export NORMALIZE_SALINITY="${OMIP_NORMALIZE_SALINITY:-false}"
export STAGING_DIR="${STAGING_DIR:-$DATA_ROOT/staging}"
export OMIP_INIT_SOURCE

if [[ "$OMIP_RESET_STAGING" == "true" ]]; then
  rm -rf "${STAGING_DIR}/${RUN_NAME}"
fi

upload_outputs_to_bucket() {
  if [[ "$OMIP_UPLOAD_OUTPUTS" != "true" ]]; then
    return 0
  fi

  if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "Skipping bucket upload because output directory does not exist: $OUTPUT_DIR" >&2
    return 0
  fi

  local destination="gs://${OMIP_BUCKET_NAME}/${OMIP_OUTPUT_BUCKET_PREFIX}/"
  echo "Uploading outputs from $OUTPUT_DIR to $destination"
  shopt -s nullglob dotglob
  local entries=("$OUTPUT_DIR"/*)
  shopt -u nullglob dotglob

  if (( ${#entries[@]} == 0 )); then
    echo "Skipping bucket upload because output directory is empty: $OUTPUT_DIR" >&2
    return 0
  fi

  gcloud --project="${GOOGLE_CLOUD_PROJECT:-rafael-sandbox-488511}" storage cp --recursive "${entries[@]}" "$destination"
}

upload_launcher_log_to_bucket() {
  if [[ "$OMIP_UPLOAD_OUTPUTS" != "true" ]]; then
    return 0
  fi

  if [[ -z "$OMIP_LAUNCHER_LOG" ]]; then
    return 0
  fi

  if [[ ! -f "$OMIP_LAUNCHER_LOG" ]]; then
    echo "Skipping launcher log upload because file does not exist: $OMIP_LAUNCHER_LOG" >&2
    return 0
  fi

  local destination="gs://${OMIP_BUCKET_NAME}/${OMIP_OUTPUT_BUCKET_PREFIX}/"
  echo "Uploading launcher log from $OMIP_LAUNCHER_LOG to $destination"
  gcloud --project="${GOOGLE_CLOUD_PROJECT:-rafael-sandbox-488511}" storage cp "$OMIP_LAUNCHER_LOG" "$destination"
}

shutdown_vm_on_exit() {
  if [[ "$OMIP_SHUTDOWN_ON_EXIT" != "true" ]]; then
    return 0
  fi

  echo "Shutting down VM after run exit"
  sudo shutdown -h now || shutdown -h now || true
}

cleanup_on_exit() {
  local exit_code=$?
  local upload_status=0
  local log_upload_status=0
  local shutdown_status=0

  echo "OMIP runner exiting with code $exit_code"

  upload_outputs_to_bucket || upload_status=$?
  upload_launcher_log_to_bucket || log_upload_status=$?
  # Leave failed short-cycle debug runs available for immediate inspection,
  # while retaining automatic shutdown for a successful completion.
  if [[ "$RUNNER_OWNS_LOCK" == "true" ]] &&
     { (( exit_code == 0 )) || [[ "$OMIP_SHUTDOWN_ON_FAILURE" == "true" ]]; }; then
    shutdown_vm_on_exit || shutdown_status=$?
  fi

  if (( upload_status != 0 )); then
    return "$upload_status"
  fi

  if (( log_upload_status != 0 )); then
    return "$log_upload_status"
  fi

  return "$shutdown_status"
}

trap cleanup_on_exit EXIT

chmod +x "$LAUNCH_SCRIPT"

cd "$PROJECT_DIR"
echo "Starting launch script: $LAUNCH_SCRIPT $OMIP_CONFIG"
launch_status=0
bash "$LAUNCH_SCRIPT" "$OMIP_CONFIG" || launch_status=$?
if (( launch_status != 0 )); then
  echo "Launch script failed with exit code $launch_status" >&2
  exit "$launch_status"
fi
echo "Launch script completed successfully"
