# PR165 1° regional Arctic run (2006)

This directory records the **completed** PR165-derived 1° Arctic integration
with ice dynamics and the new column thermodynamics. It is the corrected
bare-surface-guard baseline, not the later 1 mm snow-albedo sensitivity or an
ORCA1 integration.

## Configuration

| Component | Choice |
| --- | --- |
| Domain | 44 × 44 rotated latitude–longitude grid, 1° spacing, 1,055 wet cells |
| Ice and snow | Eight-layer column energy thermodynamics and evolving slab snow |
| Dynamics | EVP with 150 split-explicit substeps, incremental remapping, wind and basal stress |
| Atmosphere | Three-hourly JRA55-do 2006 state and snowfall |
| Ocean | GLORYS initial temperature, stationary 50 m slab with basal heat exchange |
| Initial ice | Prepared GLORYS concentration and thickness |
| Numerical step | 60 s, 525,600 steps for 365 days; `CPU()` grid, Julia two threads on EC2 |
| Checkpoints | Every 1,200 model hours (50 days) in the archived cloud run |

The ocean has no interactive circulation or open-water surface exchange in this
baseline. The year run completed its built-in ice and snow mass, surface energy,
and geometry guards; this does not mean the simulated seasonal ice extent is
unbiased. See [`result/summary.toml`](result/summary.toml) for the archived
numerical summary. The archive was verified on 13 October 2026 in
[`result/archive_status.txt`](result/archive_status.txt).

## Source and result identity

The run started from [CliMA/ClimaSeaIce.jl PR165](https://github.com/CliMA/ClimaSeaIce.jl/pull/165)
head `237ea6fb1a0236c64d9de62ebe6ea6cd6a8dc550`. The cloud job used
the local source fixes in this branch, bundled with SHA-256
`e6f112a24719cd28f422a9ca80c5c51523746ad6a0a3648922c614d7d816bf19`.
The physical `src/` tree in this commit matches that bundle. The committed
driver is byte-for-byte the cloud driver, SHA-256
`782875fd28c35d1e2e0ded33eb2090d2f10b406729b6e968f2131c047e5883b4`.

The archived 365-day result is at
`s3://arctic-reflections-iceflow-rafael/iceflow/pr165-arctic-regional/results/pr165_corrected_bare_guard_365d_20261011/`.
The verified run used the prepared input bundle with SHA-256
`74c2d50fc2e9fb07d81f9b4cebd93b0ac3de055ad36ec90f18e82141c73dba6c`.
Model outputs, input arrays, and binary checkpoints are deliberately outside
Git. The [`cloud/`](cloud/) scripts record the exact EC2 staging, preflight,
run, archiving, and shutdown steps. They contain paths and S3 object names
specific to that archived job.

## Reproduce from the prepared forcing file

The required NetCDF is
`jra55_glorys_1deg_20060101_365day_cell_centers_v6.nc`, produced by the
regional input preparation under `PR165_Arctic_Regional` in the
[`ocean_Ice_testing` repository](https://github.com/RafaelAbel/ocean_Ice_testing).
It contains the 2006 JRA55-do forcing and GLORYS-derived initial conditions.
From this repository root, export its arrays and run a one-day preflight:

```sh
CASE=validation/regional_arctic_1deg
python "$CASE/arctic-thermo/export_input.py" /path/to/jra55_glorys_1deg_20060101_365day_cell_centers_v6.nc
python "$CASE/arctic-thermo/export_precipitation.py" /path/to/jra55_glorys_1deg_20060101_365day_cell_centers_v6.nc
julia --project="$CASE/env" -e 'using Pkg; Pkg.instantiate()'
PR165_DT=60 PR165_HOURS=24 julia --project="$CASE/env" \
    "$CASE/drivers/regional_forced_column_dynamics.jl" "$CASE/outputs/preflight"
```

For a new year run, change `PR165_HOURS` to `8760` and use a fresh output
directory. Confirm the preflight `summary.toml` reports `status = "completed"`
before starting the longer integration. This script runs on the CPU; selecting
an EC2 GPU instance alone does not move the grid to a GPU.

The `env/Manifest.toml` pins the package versions used by the completed cloud
run, including Oceananigans 0.113.4. In this checkout its `../source` entry
resolves through a symlink to the repository root; in the cloud bundle it
resolved to the staged source directory.

## Commit verification

On 20 October 2026, both input exporters ran against the prepared NetCDF.
Selected output arrays (`wet`, initial thickness, air temperature, shortwave,
snowfall, and snowfall times) matched the existing archived input byte for
byte. A fresh one-hour Mac CPU run of this checkout completed with all driver
guards. Against the cloud job's one-hour preflight, 24 of 29 summary fields
matched exactly; the other five differed only at floating-point roundoff.
The archived cloud year summary reports `status = "completed"`, 8,760 model
hours, and 525,600 time steps.
