# Handoff: getting PR165 thermodynamics running in the 1° Arctic case

This is a self-contained guide for a new task. Start with the
[case README](README.md), the [actual driver](drivers/regional_forced_column_dynamics.jl),
and the [archived year summary](result/summary.toml). The branch is
`RafaelAbel/ClimaSeaIce.jl:codex/pr165-arctic-1deg`, based on the fork's
`codex/pr165-surface-flux-feedback` branch, which itself builds on
[CliMA PR165](https://github.com/CliMA/ClimaSeaIce.jl/pull/165) head
`237ea6fb1a0236c64d9de62ebe6ea6cd6a8dc550`.

## What was achieved

The **2006 regional Arctic case completed 365 model days with the new
PR165-derived eight-layer ice thermodynamics, evolving snow, and EVP ice
dynamics enabled**. The archived job reports 8,760 model hours, 525,600
60-second steps, and `status = "completed"`; the upload was verified on
13 October 2026. This is a model integration and numerical-budget result. It
is not an ORCA1 run, and completion does not establish agreement with observed
ice extent. The baseline summer sea-ice extent was high relative to the
same-mask observation comparison, so scientific tuning remains open.

The validated baseline uses a **44 × 44 rotated 1° grid** (1,055 wet cells),
three-hourly JRA55-do atmospheric forcing and snowfall, GLORYS-derived 2006
initial ice and ocean temperature, a stationary 50 m ocean slab with basal
heat exchange, 150 EVP substeps, and incremental remapping. It runs on a
`CPU()` grid, even if the EC2 host has an L4 GPU. Its snow-albedo switch is
at **10⁻⁸ m**, not 1 mm. The 1 mm snow-albedo experiment is separate; the
user asked on 19 October 2026 not to retry its January year run yet.

## Path from PR head to a verified year

1. Pin PR165 head and Oceananigans 0.113.4 in an isolated Julia project, and
   prepare the full-year 2006 JRA55-do/GLORYS forcing on the rotated grid.
   Export the NetCDF fields to column-major arrays read by the driver.
2. Construct the eight-layer thermodynamic column with slab snow and EVP
   dynamics. Feed the atmospheric flux back at each trial surface
   temperature, rotate winds into the grid's face directions, and prescribe
   basal heat exchange with the 50 m slab.
3. Reduce failures to small cases: test the thin-snow nonlinear surface
   balance without the regional forcing, then test layered energy transport
   under dynamics. Make those source fixes and run the focused regressions.
4. Add hourly finite-state, surface-energy, mass, slab-energy, and column
   geometry checks; run short preflights before longer integrations.
5. Diagnose the day-235 stop from the archived state. Correct the driver's
   timing of its bare-ice diagnostic without changing physical stepping.
6. Restart with the corrected driver, write 50-day checkpoints, archive
   daily states and hourly diagnostics, and verify the day-365 output on S3.

## What the integration required beyond pristine PR165

1. **Use and verify live surface flux feedback.** The atmospheric sensible, latent, and
   radiative heat fluxes depend on the unknown ice or snow surface
   temperature. The solver must evaluate the flux at each trial surface
   temperature. PR165 already provided the temperature-dependent
   `FluxFunction` interface; the preceding fork commit `73b438c` documented
   and tested it. The regional driver supplies
   `FluxFunction(...; top_temperature_dependent=true)`. Treating the
   atmospheric flux as a fixed number at the start of a step gives a
   different surface energy balance. This branch also contains a generic
   `LinearizedSurfaceFlux` for couplers, but this regional run uses the
   nonlinear `FluxFunction` path.
2. **Finite snow on a resolved ice column.** The column and slab-snow schemes
   needed an explicit interface that conducts heat through finite snow,
   spends snow's finite latent reservoir before excess energy reaches ice,
   evolves snow mass, and diagnoses the snow surface balance. See
   [`column_snow_time_stepping.jl`](../../src/SeaIceThermodynamics/column_snow_time_stepping.jl).
   At vanishing snow thickness the thermal path switches to bare ice at
   10⁻⁸ m. A one-cell example captured from model hour 1840.167 showed the
   original secant surface solve returning about −234 °C without converging;
   the guarded, bracketed fallback closes the surface balance. See
   [`regional_thin_snow_surface_failure.jl`](../regional_thin_snow_surface_failure.jl).
3. **Dynamics must carry column properties.** Advecting ice area, ice volume,
   and snow alone left the layered internal-energy pattern behind. The
   committed incremental-remapping path transports each layer's internal
   energy with the same ice-volume flux, and prognostic salinity when used.
   It updates these intensive properties while the donor ice state is still
   available, then synchronizes the moving column interfaces after the
   horizontal thickness update. See
   [`incremental_remapping.jl`](../../src/incremental_remapping.jl) and
   [`sea_ice_fe_step.jl`](../../src/sea_ice_fe_step.jl).
4. **Do not solve a nonexistent ice surface.** The surface-temperature
   diagnostic now avoids masked land and zero-height ice columns, where a
   conductive surface balance is undefined. The same one-cell regression
   checks this case. The branch also transfers the mutable column-coordinate
   arrays through Oceananigans' `on_architecture` path; this is preparatory
   for GPU execution, not proof that this regional driver uses a GPU.

The source code in this branch matches the physical `src/` tree in the
source bundle used for the completed cloud run (bundle SHA-256
`e6f112a24719cd28f422a9ca80c5c51523746ad6a0a3648922c614d7d816bf19`).
The regional driver matches the archived file byte for byte (SHA-256
`782875fd28c35d1e2e0ded33eb2090d2f10b406729b6e968f2131c047e5883b4`).

## The day-235 stop was a diagnostic timing error

An earlier year attempt stopped at **model hour 5663** with a
`Bare frozen surface balance failed` message. The driver had selected the
bare-ice check using snow depth **before** dynamics, whereas thermodynamics
used the snow depth **after** dynamics. At the failing cell, snow crossed the
10⁻⁸ m threshold during advection. That changed albedo from 0.65 to 0.80
for the thermodynamic solve; the driver's old check used 0.65 and reported
a spurious 13.792 W m⁻² residual. The corrected driver captures ice and
snow state between dynamics and thermodynamics and checks the branch the
model actually used. A one-hour corrected replay had a byte-identical final
physical state, and the previously failing hour passed. **This particular
stop did not require changing the thermodynamic physics.**

## Evidence and how to reproduce

- The [archived status](result/archive_status.txt) says `completed_year`;
  the [year summary](result/summary.toml) reports all built-in mass,
  snow-surface, geometry, and ocean-slab budget guards passing.
- On 20 October 2026, the two input exporters reproduced selected binary
  forcing arrays byte for byte from the prepared NetCDF. A fresh one-hour
  CPU replay completed; 24 of 29 summary fields matched the archived cloud
  preflight exactly and five differed at floating-point roundoff.
- `TEST_GROUP=surface_flux` and `TEST_GROUP=column_energy` passed on the
  published branch, including the captured thin-snow example. See the
  [case README](README.md) for exact input and Julia commands. The package
  environment pins Oceananigans 0.113.4.
- The full cloud result, including logs and checkpoints, is under
  `s3://arctic-reflections-iceflow-rafael/iceflow/pr165-arctic-regional/results/pr165_corrected_bare_guard_365d_20261011/`.
  Access to that S3 bucket requires the owner's AWS credentials. The public
  GitHub branch contains code and small outcome records, not forcing arrays
  or binary model output.

## Boundaries for follow-on work

Do not infer that ORCA1, a coupled ocean, or a GPU year run has passed from
this result. The 1° baseline uses a fixed geographic grid, a stationary slab
ocean, and a CPU driver. The original PR165 repository has GPU-capable model
paths, but this exact regional driver explicitly constructs a `CPU()` grid;
changing EC2 instance type alone cannot accelerate it with a GPU. A GPU port
needs its own preflight and CPU/GPU budget comparison.

For scientific follow-up, compare SIE, SIA, volume, snow cover, and ocean
heat flux against the **same observational mask** before judging a tuning
change. Keep the completed baseline distinct from the later 1 mm snow-albedo
and ocean-restoring sensitivities. A lower SIE by itself is not a sufficient
energy-budget or physical-validity check.

## Suggested first prompt for a new task

> Read `validation/regional_arctic_1deg/HANDOFF.md` and `README.md` on branch
> `codex/pr165-arctic-1deg` of `RafaelAbel/ClimaSeaIce.jl`. Treat the archived 365-day CPU run as the verified
> baseline. Identify the exact next experiment before changing physics or
> launching cloud resources, and preserve the run's source and input hashes.
