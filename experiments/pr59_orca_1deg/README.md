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

## PR141 BL99 eight-layer ORCA1 smoke path

`patches/numericalearth_pr59_ecco_pr141_bl99_8layer_init_patch.jl` adds the
validated PR141 fixed-salinity BL99 column thermodynamics to the same ORCA1
ECCO/JRA55 setup. It builds a dedicated, eight-layer ORCA sea-ice grid and
initializes thickness and concentration from ECCO. Ice dynamics are hard-coded
to `nothing` in the constructor; the launch environment cannot enable them.

The path packages the last PR59 source commit before the June 8 baseline run
(`bf1f9fcf`) rather than a moving upstream PR reference. It preserves the
baseline NumericalEarth and
JRA55 forcing interfaces and resolves the coherent historical package family:
NumericalEarth 0.5.4, Oceananigans 0.108.2, SeawaterPolynomials 0.3.10, and
the packaged PR141 source reported as 0.5.7. The only source-local fixes are
the two Julia-1.12 PR141 compatibility adjustments. After committing the
branch, launch the five-day GPU smoke test with:

```bash
bash runner/provision_pr141_bl99_8layer_orca1_gpu.sh
```

It packages the exact committed PR141 source and the pinned baseline, uploads
them with the dedicated adapter, writes diagnostics including `surface.jld2`,
uploads outputs to the bucket, and shuts the VM down on exit. The
old-thermodynamics path above remains unchanged.

### Confirmed five-day coupled gate

The corrected PR141 eight-layer, no-dynamics GPU smoke run completed on 2026-08-12:

- model time: **5 days**
- final iteration: **360** (20-minute timestep)
- output prefix:
  `gs://sea_ice/outputs/numericalearth_pr59/a100_ecco_pr141_bl99_8layer_orca1_coupled_5day_t4_retry2_20260813/`
- verified artifact: `surface.jld2`, containing `siconc`
- verified evolution over the five-day records: `sithick` changed in 5,573
  cells (maximum absolute change 0.116 m) and `siconc` changed in 5,589 cells
  (maximum absolute change 0.463)

The run exited successfully, uploaded surface, 3-D, averages, and checkpoint
artifacts, and automatically shut down the GPU VM. This supersedes the earlier
five-day output, which demonstrated the launch path but predated the coupled
ice-volume update. The next milestone is the same configuration for 30 days.

### Confirmed coupled 30-day gate

The corrected PR141 eight-layer, no-dynamics configuration completed its
30-day GPU milestone on 2026-08-13:

- model time: **30 days**
- final iteration: **2,160** (20-minute timestep)
- output prefix:
  `gs://sea_ice/outputs/numericalearth_pr59/a100_ecco_pr141_bl99_8layer_orca1_coupled_30day_t4_20260813/`
- verified artifact: `surface.jld2`, containing `siconc`
- verified evolution over the 30-day records: `sithick` changed in 6,730
  cells (maximum absolute change 1.123 m) and `siconc` changed in 6,746 cells
  (maximum absolute change 0.970)

It exited with code 0, uploaded surface, 3-D, averages, and checkpoint
artifacts, and cleanly auto-shut down the GPU VM. This is the coupled
ice-volume path; it supersedes the earlier 30-day output that predated the
coupling fix. The next milestone is the same configuration for a full 365-day
year.

### Confirmed coupled 365-day run

The same PR141 BL99 eight-layer, no-dynamics configuration completed a full
year on an A100 on 2026-08-13:

- source commit: `ab929a3`
- model time: **365 days**
- final iteration: **26,280** (20-minute timestep)
- output prefix:
  `gs://sea_ice/outputs/numericalearth_pr59/a100_ecco_pr141_bl99_8layer_orca1_coupled_365day_a100_20260813/`
- final checkpoint: `checkpoint_iteration25920.jld2`
- launcher outcome: exit code **0**, followed by output upload and automatic
  VM shutdown

The surface diagnostic contains `siconc`; the final, readable records give an
Arctic 15%-threshold extent of **3.486 million km² at day 360** and **3.482
million km² at day 365**. During the run, independent diagnostic checks
confirmed that `sithick` and `siconc` evolved (at day 70, 8,018 cells had
changed in each field, with maximum changes of 2.133 m and 0.970,
respectively).

The uploaded `surface_part1.jld2` is structurally unreadable after transfer,
whereas `surface_part2.jld2` is readable. This prevents reconstructing the
complete five-day surface-extent series from the uploaded artifacts and must
be fixed before using this year run for a full seasonal SIE comparison. It
does not affect the verified model completion, final checkpoint, or the
readable final surface diagnostics.

For the January 2006 start, the runner also stages the four 2005 JRA55
boundary records from the existing project bucket. This is the same forcing
used at the start boundary and avoids a slow external ESGF download.

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
