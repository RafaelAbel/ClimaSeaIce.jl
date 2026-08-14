
<p align="center">
  <a href="https://doi.org/10.5281/zenodo.16143708" >
    <img src="https://zenodo.org/badge/DOI/10.5281/zenodo.16143708.svg?style=flat-square"/>
  </a>
  <a href="https://codecov.io/gh/CliMA/ClimaSeaIce.jl" >
    <img src="https://codecov.io/gh/CliMA/ClimaSeaIce.jl/graph/badge.svg?token=3Smw4jVzZG"/>
  </a>
  <a href="https://clima.github.io/ClimaSeaIceDocumentation/dev">
    <img alt="Development documentation" src="https://img.shields.io/badge/documentation-in%20development-orange">
  </a>
</p>

<!-- Title -->
<h1 align="center">
  ClimaSeaIce.jl
</h1>

<!-- description -->
<p align="center">
  <strong>🧊 Fast and friendly Julia software for simulating the freezing, melting, and horizontal motion of salty ice on CPUs and GPUs.</strong>
</p>


ClimaSeaIce is a library that empowers users to configure and run simulations of sea ice freezing, melting, and horizontal motion on the
large time and spatial scales appropriate for climate modeling.
We support stand-alone simulations of sea ice dynamics as well as simulations coupled to ocean models based on [Oceananigans]().

## [Documentation!](https://clima.github.io/ClimaSeaIceDocumentation/dev/)

Our documentation and source code are works in progress.
When things have progressed, we'll put an outline here.

### PR141 BL99 local column sandbox

Before using an ORCA grid or GPU, the eight-layer PR141 phase-boundary and
concentration logic can be exercised on one CPU cell with controlled fluxes:

```bash
julia --project=. experiments/pr141_bl99_column_sandbox.jl open_water_gradient
julia --project=. experiments/pr141_bl99_column_sandbox.jl edge_freezing
julia --project=. experiments/pr141_bl99_column_sandbox.jl consolidated_ice
```

The first case proves that the allocated initial temperature gradient cannot
create ice in open water. The second proves that a physical ocean freezing
flux can create thin partial ice without the runaway; the third covers an
already consolidated ice column. Use `PR141_SANDBOX_DAYS` and
`PR141_SANDBOX_BOTTOM_FLUX` to change the duration or forcing.

### Citing

If you use ClimaSeaIce for your research, teaching, or fun 🤩, everyone in our community will be grateful
if you give credit by citing the corresponding Zenodo record, e.g.,

> Silvestri, S. et al. (2026). CliMA/ClimaSeaIce.jl: v0.5.1 (v0.5.1). Zenodo. https://doi.org/10.5281/zenodo.16143708
