# PR59 ORCA 1° ECCO/JRA55 GPU run

This directory preserves the working launch and analysis path for the
old-thermodynamics NumericalEarth PR59 ORCA 1° configuration. It is kept here
as an experiment harness: NumericalEarth remains an external PR59 dependency,
while this repository provides the patched initialization, cloud runner, and
reproducible extent analysis.

## Confirmed run

The A100 rerun completed on 2026-08-10:

- model time: **365 days**
- final iteration: **26,280**
- output prefix:
  `gs://sea_ice/outputs/numericalearth_pr59/a100_ecco_1year_baseline_rerun_20260810_recoveryc4/`
- final surface output:
  `orca_corrected_snow_kskew800_ksymm800_bih50days_surface_part1.jld2` and
  `orca_corrected_snow_kskew800_ksymm800_bih50days_surface_part2.jld2`

The run is therefore operational, including bucket upload and VM shutdown.
It is **not** an acceptable replacement baseline yet: its July/August Arctic
sea-ice extent was only **0.79 / 0.62 million km²**, compared with **8.46 /
6.50 million km²** in NSIDC Sea Ice Index monthly observations for 2006.
The earlier PR59 baseline and re-icing year runs retained substantially more
summer ice. Diff the NumericalEarth/ClimaSeaIce input revisions before using
this rerun for scientific comparison.

## Configuration

The successful configuration was:

```bash
BIHARMONIC=50days CORRECTED=true SNOW=true KSKEW=800 KSYMMETRIC=800 ./launch.sh orca
```

The GPU runner uses:

- NumericalEarth PR59 source,
- ECCO4 January 2006 ocean and sea-ice initialization,
- JRA55 2006 atmospheric forcing,
- old ClimaSeaIce thermodynamics pinned at `d6b9bbc32867eea61008b3b8c5ac5faaa9adf416`
  (the former `ss/correct-bugs` branch), and
- `20minutes` timestep with diagnostics every five model days.

The runner expects pre-staged inputs in the `sea_ice` bucket. It never stores
credentials or input NetCDF files in this repository.

## Launching on a prepared GPU VM

Copy the three files below to the VM, then run the VM runner with the recorded
settings. The runner hydrates ECCO/JRA55 data from the bucket, fetches the
NumericalEarth PR59 source, applies its temporary compatibility wiring, uploads
outputs, and can stop the VM after exit.

```bash
export OMIP_ARCH=gpu
export OMIP_INIT_SOURCE=ecco
export OMIP_STOP_TIME=365days
export OMIP_DT=20minutes
export OMIP_WITH_SNOW=true
export OMIP_UPLOAD_OUTPUTS=true
export OMIP_SHUTDOWN_ON_EXIT=true
export OMIP_OUTPUT_BUCKET_PREFIX=outputs/numericalearth_pr59/<new-run-name>
export PATCH_SCRIPT=/home/rafaelabel/numericalearth_pr59_ecco_old_thermo_init_patch.jl
export LAUNCH_SCRIPT=/home/rafaelabel/numericalearth_pr59_launch_cloud.sh
export BIHARMONIC=50days CORRECTED=true SNOW=true KSKEW=800 KSYMMETRIC=800
bash /home/rafaelabel/run_numericalearth_pr59_omip_on_vm.sh
```

`runner/run_numericalearth_pr59_omip_on_vm.sh` documents every required input
path and bucket prefix. The runtime compatibility edits are deliberately made
only in its ephemeral VM source tree; the package source in this branch is not
silently modified by a launch.

## Extent analysis

Use `analysis/export_arctic_sie.jl` once per run to create a compact CSV from
the two `surface_part*.jld2` outputs. It calculates Northern Hemisphere extent
from cells with `siconc ≥ 0.15`.

```bash
julia --project=/path/to/NumericalEarth.jl/experiments/OMIPSimulations \
  analysis/export_arctic_sie.jl current_sie.csv surface_part1.jld2 surface_part2.jld2

python3 analysis/compare_2006_sie.py \
  --nsidc-dir /path/to/N_01_extent_v4.0.csv-parent \
  --current current_sie.csv --baseline baseline_sie.csv --reicing reicing_sie.csv \
  --summary monthly_extent_2006.csv --figure monthly_extent_2006.png
```

The comparison uses NSIDC Sea Ice Index v4 monthly data. Its regional mask is
not identical to the model Northern Hemisphere mask, so it is a robust
seasonal diagnostic rather than a grid-identical validation.
