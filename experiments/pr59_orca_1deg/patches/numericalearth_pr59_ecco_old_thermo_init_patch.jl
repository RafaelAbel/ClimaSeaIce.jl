using NumericalEarth
using OMIPSimulations
using Oceananigans
using Oceananigans.Units
using Dates
using Downloads: Downloads

import OMIPSimulations: build_ocean, build_sea_ice

function Downloads.download(metadata::NumericalEarth.DataWrangling.Metadata{<:typeof(ECCO4Monthly())};
                            skip_existing = true)
    paths = metadata isa NumericalEarth.DataWrangling.Metadatum ?
        [NumericalEarth.DataWrangling.metadata_path(metadata)] :
        NumericalEarth.DataWrangling.metadata_path(metadata)

    missing_paths = filter(path -> !isfile(path), paths)
    isempty(missing_paths) || error(
        "Missing pre-staged ECCO file(s): $(join(missing_paths, ", ")). " *
        "Stage the required ECCO NetCDF files before launch."
    )

    return metadata isa NumericalEarth.DataWrangling.Metadatum ? only(paths) : paths
end

function build_ocean(config, grid;
                     κ_skew, κ_symmetric, Cᵇ = 0.28,
                     restoring_dir, piston_velocity,
                     biharmonic_timescale,
                     biharmonic_viscosity = nothing,
                     vertical_closure = :catke,
                     Cᵂu★ = nothing,
                     start_date, end_date)

    ecco_dir = get(ENV, "OMIP_ECCO_DIR", restoring_dir)
    ecco_dataset = ECCO4Monthly()

    closure = OMIPSimulations.omip_closure(
        vertical_closure;
        κ_skew,
        κ_symmetric,
        Cᵇ,
        biharmonic_timescale,
        biharmonic_viscosity,
        Cᵂu★,
    )

    coriolis = HydrostaticSphericalCoriolis(scheme = Oceananigans.Coriolis.EnstrophyConserving())
    momentum_advection = OMIPSimulations.config_momentum_advection(config)

    ocean = NumericalEarth.ocean_simulation(
        grid;
        Δt = 1minutes,
        momentum_advection,
        tracer_advection = WENO(
            order = 7;
            minimum_buffer_upwind_order = 3,
            time_discretization = AdaptiveVerticallyImplicitDiscretization(cfl = 0.4),
        ),
        coriolis,
        timestepper = :SplitRungeKutta3,
        materialize_buoyancy_gradients = !(config == Val(:tenthdegree)),
        free_surface = SplitExplicitFreeSurface(grid; substeps = 70),
        closure,
    )

    set!(
        ocean.model,
        T = Metadatum(:temperature; date = start_date, dataset = ecco_dataset, dir = ecco_dir),
        S = Metadatum(:salinity; date = start_date, dataset = ecco_dataset, dir = ecco_dir),
        u = Metadatum(:u_velocity; date = start_date, dataset = ecco_dataset, dir = ecco_dir),
        v = Metadatum(:v_velocity; date = start_date, dataset = ecco_dataset, dir = ecco_dir),
    )

    return ocean
end

function build_sea_ice(config, grid, ocean; restoring_dir, snow_thermodynamics = nothing,
                       with_ice_dynamics = true)
    ecco_dir = get(ENV, "OMIP_ECCO_DIR", restoring_dir)
    ecco_dataset = ECCO4Monthly()
    init_date = DateTime(get(ENV, "OMIP_START_DATE", "2006-01-01T00:00:00"))

    dynamics = with_ice_dynamics ? NumericalEarth.SeaIces.sea_ice_dynamics(grid, ocean) : nothing
    sea_ice = NumericalEarth.sea_ice_simulation(
        grid,
        ocean;
        advection = WENO(
            order = 7,
            minimum_buffer_upwind_order = 1,
            weight_computation = Oceananigans.Utils.NormalDivision,
        ),
        dynamics,
        snow_thermodynamics,
    )

    set!(
        sea_ice.model,
        h = Metadatum(:sea_ice_thickness; date = init_date, dataset = ecco_dataset, dir = ecco_dir),
        ℵ = Metadatum(:sea_ice_concentration; date = init_date, dataset = ecco_dataset, dir = ecco_dir),
    )

    return sea_ice
end
