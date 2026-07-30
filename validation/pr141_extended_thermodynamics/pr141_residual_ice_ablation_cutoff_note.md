# PR141 Residual-Ice A/B Note

Last updated: 2026-07-30

## Purpose

This note records a reduced Arctic PR141 A/B test that isolates the late-time residual-ice instability.

The question was:

- does the reduced PR141 example fail because a nearly vanished sea-ice cell is still treated as active?
- and does a tiny active-volume cutoff remove that failure?

## Setup

Shared setup for both runs:

- driver: `run/arctic_rotated_glorys12_jra55_pr141_column_delta12_32x32_cpu_example.jl`
- shared slab driver: `run/arctic_rotated_glorys12_jra55_slab.jl`
- architecture: CPU
- grid: `32 x 32 x 20`
- depth: `50 m`
- run length: `24 h`
- timestep: `10 s`
- PR141 thermodynamics: `pr141_column`
- PR141 bottom heat flux: `-10 W m^-2`
- PR141 bulk salinity: `4 psu`
- initial PR141 ice temperature: `-10 C`
- PR141 dynamics disabled: `true`

Both runs included the thermodynamic-side fixes already present in the clean PR141 tree:

- physical absolute-zero floor in `src/SeaIceThermodynamics/column_energy_relations.jl`
- `MeltingLimitedSurfaceFlux` at the PR141 top boundary

This means the A/B test only changes the residual-ice cutoff.

## Cases

### Case A: no cutoff

Env settings:

- `ARCTIC_PR141_MIN_ACTIVE_THICKNESS_M=0`
- `ARCTIC_PR141_MIN_ACTIVE_CONCENTRATION=0`
- `ARCTIC_PR141_MIN_ACTIVE_VOLUME_M=0`

Observed result:

- failed at `time = 19.633 hours`
- failed at `iteration = 7068`
- first non-finite field: `top_heat_flux`

Offending cell:

- `i = 1`
- `j = 29`
- `ice_thickness = 0.0240333192050457 m`
- `ice_concentration = 0.007063545286655426`
- active ice volume `h * ℵ ≈ 1.697e-4 m`
- `top_heat_flux = NaN`
- `top_surface_temperature = -273.1499999999999`
- `interface_temperature = -273.1499999999999`

Diagnostic interpretation:

- the cell is not meaningfully ice-covered anymore, but it is still treated as active because `ℵ > 0`
- the atmosphere/ice coupling still produces a cell-mean top flux for that cell
- the thermodynamic update then converts that cell-mean flux into a per-ice-column flux through the `1 / ℵ` scaling path
- once `ℵ` is this small, the residual cell becomes numerically singular and `top_heat_flux` goes non-finite

### Case B: volume cutoff only

Env settings:

- `ARCTIC_PR141_MIN_ACTIVE_THICKNESS_M=0`
- `ARCTIC_PR141_MIN_ACTIVE_CONCENTRATION=0`
- `ARCTIC_PR141_MIN_ACTIVE_VOLUME_M=0.002`

Observed result:

- `completed=true`
- `final_model_time=1 day`
- `iterations=8640`
- `run_started_utc=2026-07-30T14:20:42.350`
- `run_finished_utc=2026-07-30T14:30:05.965`
- `runtime_seconds=563.613515216`

## Comparison

| Case | Cutoff | Outcome |
| --- | --- | --- |
| A | none | fails at `19.633 h` with `top_heat_flux = NaN` in a tiny residual cell |
| B | `h * ℵ <= 0.002 m` | completes full `24 h` run |

## What this shows

This A/B result is strong evidence that the problematic regime is the residual-ice limit itself.

The useful model-level statement is:

- the current PR141 coupling path is unstable when a cell retains a very small but nonzero sea-ice fraction and thickness
- the instability is not the earlier `12 h` cold-side thermodynamic failure, because both cases pass that point
- the failure is specifically tied to a nearly vanished cell remaining active long enough for the atmosphere/ice flux calculation and the `1 / ℵ` thermodynamic scaling to produce a non-finite top flux

So the flaw is better described as:

- the small-active-ice limit is numerically singular in the current coupling/update path

and not just:

- "tiny ice stays active"

## Implication for next tests

This reduced test removes one important blocker for returning to the PR141 1/12 degree smoke path.

The next reasonable step is:

1. run the existing `1/12 degree` PR141 smoke case
2. apply the same residual active-volume cutoff
3. keep the same non-finite diagnostics enabled
4. check whether the 5-day smoke run remains stable
