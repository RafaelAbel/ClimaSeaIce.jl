using NumericalEarth
using OMIPSimulations
using Oceananigans
using Oceananigans.Units
using ClimaSeaIce
using Dates
using Downloads: Downloads
using Adapt
using Oceananigans.Architectures: architecture
using Oceananigans.Grids: Center, MutableVerticalDiscretization
using Oceananigans.Simulations: Simulation

import OMIPSimulations: build_ocean, build_sea_ice

const CSIT = ClimaSeaIce.SeaIceThermodynamics
const PR141_ICE_LAYERS = 8

# The legacy OMIP radiation code indexes a 2-D surface-temperature object as
# `[i, j, 1]`. PR141 stores an eight-layer temperature column instead; this
# lightweight view maps that legacy access to the physical top ice layer.
struct PR141TopLayerTemperature{T}
    temperature :: T
end

@inline Base.getindex(T::PR141TopLayerTemperature, i, j, k) =
    @inbounds T.temperature[i, j, PR141_ICE_LAYERS]

Adapt.adapt_structure(to, T::PR141TopLayerTemperature) =
    PR141TopLayerTemperature(Adapt.adapt(to, T.temperature))

# Column boundary conditions own live Oceananigans fields, so they must be
# adapted explicitly when the sea-ice model moves to the GPU.
function Adapt.adapt_structure(to, boundary::CSIT.PrescribedEnergyFlux)
    return CSIT.PrescribedEnergyFlux(Adapt.adapt(to, boundary.flux))
end

function Adapt.adapt_structure(to, boundary::CSIT.MeltingLimitedSurfaceFlux)
    return CSIT.MeltingLimitedSurfaceFlux(Adapt.adapt(to, boundary.flux))
end

function Adapt.adapt_structure(to, boundary_conditions::CSIT.ColumnBoundaryConditions)
    return CSIT.ColumnBoundaryConditions(top = Adapt.adapt(to, boundary_conditions.top),
                                         bottom = Adapt.adapt(to, boundary_conditions.bottom))
end

@inline pr141_boundary_flux_value(flux::Oceananigans.Fields.AbstractField, i, j) = @inbounds flux[i, j, 1]
@inline pr141_boundary_flux_value(flux::AbstractArray{<:Any, 2}, i, j) = @inbounds flux[i, j]
@inline pr141_boundary_flux_value(flux::AbstractArray{<:Any, 3}, i, j) = @inbounds flux[i, j, 1]

@inline function CSIT.column_boundary_energy_flux(boundary::CSIT.PrescribedEnergyFlux{F},
                                                  i, j, k, grid, fields, relation, Δt) where
                                                  {F <: Union{Oceananigans.Fields.AbstractField, AbstractArray}}
    return pr141_boundary_flux_value(boundary.flux, i, j)
end

@inline function CSIT.column_boundary_energy_flux(boundary::CSIT.MeltingLimitedSurfaceFlux{F},
                                                  i, j, k, grid, fields, relation, Δt) where
                                                  {F <: Union{Oceananigans.Fields.AbstractField, AbstractArray}}
    Δz = CSIT.current_column_cell_thickness(i, j, k, grid)
    E = @inbounds fields.internal_energy[i, j, k]
    S = @inbounds fields.bulk_salinity[i, j, k]
    requested_flux = pr141_boundary_flux_value(boundary.flux, i, j)
    available_flux = CSIT.column_energy_to_complete_melt(relation, E, S, Δz) / Δt
    return min(requested_flux, max(available_flux, zero(available_flux)))
end

function pr141_orca_dataset()
    orca = NumericalEarth.DataWrangling.ORCA
    isdefined(orca, :ORCAOne) && return getfield(orca, :ORCAOne)()
    isdefined(orca, :ORCA1) && return getfield(orca, :ORCA1)()
    error("No ORCA one-degree dataset constructor found.")
end

function pr141_orca_sea_ice_grid(grid)
    return NumericalEarth.Bathymetry.ORCAGrid(
        architecture(grid);
        dataset = pr141_orca_dataset(),
        Nz = PR141_ICE_LAYERS,
        z = MutableVerticalDiscretization((0, 1)),
        halo = (8, 8, 8),
        with_bathymetry = true,
        active_cells_map = true,
    )
end

function pr141_thermodynamics(grid, top_heat_flux, bottom_heat_flux)
    FT = eltype(grid)
    relation = CSIT.FixedSalinityBrinePocketEnergyRelation(FT)
    salinity_profile = CSIT.FixedDrainedIceSalinityProfile(FT)
    transport = CSIT.ConductiveTemperatureTransport(
        conductivity = CSIT.MaykutUntersteinerConductivity(FT),
    )
    boundary_conditions = CSIT.ColumnBoundaryConditions(
        top = CSIT.MeltingLimitedSurfaceFlux(top_heat_flux.data),
        bottom = CSIT.PrescribedEnergyFlux(bottom_heat_flux.data),
    )
    thermodynamics = CSIT.prescribed_salinity_enthalpy_thermodynamics(
        grid;
        relation,
        salinity_profile = zero(FT),
        energy_transport = transport,
        boundary_conditions,
    )
    set!(thermodynamics;
         bulk_salinity = (λ, φ, z) -> salinity_profile(z),
         temperature = (λ, φ, z) -> -2 + (-10 + 2) * z)
    return thermodynamics
end

function Downloads.download(metadata::NumericalEarth.DataWrangling.Metadata{<:typeof(ECCO4Monthly())};
                            skip_existing = true)
    paths = metadata isa NumericalEarth.DataWrangling.Metadatum ?
        [NumericalEarth.DataWrangling.metadata_path(metadata)] :
        NumericalEarth.DataWrangling.metadata_path(metadata)

    missing_paths = filter(path -> !isfile(path), paths)
    isempty(missing_paths) || error(
        "Missing pre-staged ECCO file(s): $(join(missing_paths, ", ")). " *
        "Stage the required ECCO NetCDF files before launch.")

    return metadata isa NumericalEarth.DataWrangling.Metadatum ? only(paths) : paths
end

function build_ocean(config, grid;
                     κ_skew, κ_symmetric, Cᵇ = 0.28,
                     restoring_dir, piston_velocity,
                     biharmonic_timescale,
                     biharmonic_viscosity = nothing,
                     vertical_closure = :catke,
                     implicit_vertical_advection = true,
                     skew_flux_formulation = :diffusive,
                     nemo_eddy_coefficients = nothing,
                     cesm_eddy_coefficients = nothing,
                     hybrid_eddy_coefficients = nothing,
                     eddy_slope_limiter = nothing,
                     restoring_under_sea_ice = true,
                     Cᵂu★ = nothing,
                     normalize_salinity = true,
                     additional_tracer_closure = nothing,
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
    closure = isnothing(additional_tracer_closure) ? closure : (closure..., additional_tracer_closure)

    coriolis = HydrostaticSphericalCoriolis(scheme = Oceananigans.Coriolis.EnstrophyConserving())
    # The frozen June baseline predates the adaptive vertical-discretization
    # API. Retain its fixed vertically implicit scheme for the coupled ORCA
    # integration; this leaves the requested PR141 sea-ice physics unchanged.
    time_discretization = implicit_vertical_advection ?
        VerticallyImplicitTimeDiscretization() : ExplicitTimeDiscretization()
    momentum_advection = WENOVectorInvariant(order = 5)

    ocean = NumericalEarth.ocean_simulation(
        grid;
        Δt = 1minutes,
        momentum_advection,
        tracer_advection = WENO(
            order = 7;
            minimum_buffer_upwind_order = 3,
        ),
        coriolis,
        timestepper = :SplitRungeKutta3,
        materialize_buoyancy_gradients = true,
        free_surface = SplitExplicitFreeSurface(grid; substeps = 100),
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
    config == Val(:orca) || error("The PR141 BL99 path supports only the one-degree ORCA configuration.")
    snow_thermodynamics === nothing || @warn "PR141 BL99 path does not yet enable snow thermodynamics."

    ecco_dir = get(ENV, "OMIP_ECCO_DIR", restoring_dir)
    ecco_dataset = ECCO4Monthly()
    init_date = DateTime(get(ENV, "OMIP_START_DATE", "2006-01-01T00:00:00"))

    # Deliberately fixed: this initial integration validates thermodynamics
    # without exposing the previously unreliable dynamics control path.
    dynamics = nothing
    sea_ice_grid = pr141_orca_sea_ice_grid(grid)
    top_heat_flux = Oceananigans.Fields.Field{Center, Center, Nothing}(sea_ice_grid)
    bottom_heat_flux = Oceananigans.Fields.Field{Center, Center, Nothing}(sea_ice_grid)
    snowfall = Oceananigans.Fields.Field{Center, Center, Nothing}(sea_ice_grid)
    thermodynamics = pr141_thermodynamics(sea_ice_grid, top_heat_flux, bottom_heat_flux)

    sea_ice_model = ClimaSeaIce.SeaIceModel(
        sea_ice_grid;
        ice_salinity = 4,
        ice_consolidation_thickness = 0.05,
        advection = WENO(
            order = 7,
            minimum_buffer_upwind_order = 1,
            weight_computation = Oceananigans.Utils.NormalDivision,
        ),
        dynamics,
        top_heat_flux,
        bottom_heat_flux,
        snowfall,
        phase_transitions = thermodynamics.relation.phase_transitions,
        ice_thermodynamics = thermodynamics,
        snow_thermodynamics = nothing,
    )
    sea_ice = Simulation(sea_ice_model; Δt = 5minutes, stop_time = Inf, verbose = false)

    set!(
        sea_ice.model,
        h = Metadatum(:sea_ice_thickness; date = init_date, dataset = ecco_dataset, dir = ecco_dir),
        ℵ = Metadatum(:sea_ice_concentration; date = init_date, dataset = ecco_dataset, dir = ecco_dir),
    )

    @info "Using PR141 BL99 eight-layer sea-ice path with dynamics hard-coded off" ice_layers = PR141_ICE_LAYERS with_ice_dynamics_requested = with_ice_dynamics
    return sea_ice
end

function OMIPSimulations.build_coupled_model(ocean, sea_ice, atmosphere, radiation, land, flux_configuration;
                                             velocity_formulation::Symbol = :relative,
                                             ocean_minimum_salinity = 1)
    FT = eltype(ocean.model.grid)
    IC = NumericalEarth.EarthSystemModels.InterfaceComputations
    ESM = NumericalEarth.EarthSystemModels
    if flux_configuration == :default
        interfaces = IC.ComponentInterfaces(atmosphere, ocean, sea_ice;
                                            radiation,
                                            land,
                                            ocean_minimum_salinity = convert(FT, ocean_minimum_salinity))
    else
        velocity = velocity_formulation == :relative ? IC.RelativeVelocity() :
                   velocity_formulation == :wind ? IC.WindVelocity() :
                   error("Unknown velocity_formulation: $velocity_formulation")
        if flux_configuration == :corrected || flux_configuration == :shear_aware
            interfaces = IC.ComponentInterfaces(
                atmosphere, ocean, sea_ice;
                radiation,
                land,
                atmosphere_ocean_fluxes = OMIPSimulations.corrected_atmosphere_ocean_fluxes(FT),
                atmosphere_sea_ice_fluxes = OMIPSimulations.corrected_atmosphere_sea_ice_fluxes(FT),
                sea_ice_ocean_heat_flux = OMIPSimulations.corrected_ice_ocean_heat_flux(),
                atmosphere_ocean_velocity_difference = velocity,
                atmosphere_sea_ice_velocity_difference = velocity,
                ocean_minimum_salinity = convert(FT, ocean_minimum_salinity),
            )
        elseif flux_configuration == :ncar
            interfaces = IC.ComponentInterfaces(
                atmosphere, ocean, sea_ice;
                radiation,
                land,
                atmosphere_ocean_fluxes = OMIPSimulations.ncar_atmosphere_ocean_fluxes(FT),
                atmosphere_sea_ice_fluxes = OMIPSimulations.ncar_atmosphere_sea_ice_fluxes(FT),
                sea_ice_ocean_heat_flux = OMIPSimulations.corrected_ice_ocean_heat_flux(),
                atmosphere_ocean_velocity_difference = velocity,
                atmosphere_sea_ice_velocity_difference = velocity,
                ocean_minimum_salinity = convert(FT, ocean_minimum_salinity),
            )
        else
            error("Unknown flux_configuration: $flux_configuration")
        end
    end

    return ESM.OceanSeaIceModel(ocean, sea_ice; atmosphere, radiation, land, interfaces)
end
