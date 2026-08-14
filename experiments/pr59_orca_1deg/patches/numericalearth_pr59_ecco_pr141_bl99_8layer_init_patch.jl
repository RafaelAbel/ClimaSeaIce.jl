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

# The frozen interface also writes its solved skin temperature back through
# this view. Keep the exchange two-way by updating PR141's physical top cell.
@inline Base.setindex!(T::PR141TopLayerTemperature, value, i, j, k) =
    (@inbounds T.temperature[i, j, PR141_ICE_LAYERS] = value)

Adapt.adapt_structure(to, T::PR141TopLayerTemperature) =
    PR141TopLayerTemperature(Adapt.adapt(to, T.temperature))

# NumericalEarth's frozen ORCA coupling layer predates column thermodynamics:
# its atmospheric skin-temperature and ocean three-equation closures require a
# slab `ConductiveFlux` plus a 2-D internal temperature. The PR141 column owns
# its conductive transport internally, but its bottom cell is directly usable
# as that legacy internal-temperature field. Keep this bridge deliberately
# local to the outer coupling; the eight-layer BL99 energy transport remains
# the Maykut-Untersteiner column solver configured below.
const PR141_LEGACY_INTERFACE_CONDUCTIVITY = 2.03
const PR141_IC = NumericalEarth.EarthSystemModels.InterfaceComputations
const PR141_ESM = NumericalEarth.EarthSystemModels

# Oceananigans 0.108 calls a first-step preparation hook before invoking the
# archived coupled-model stepper. The June baseline's EarthSystemModel predates
# that hook, so initialize its exchange state exactly once using its existing
# update_state! implementation.
function Oceananigans.TimeSteppers.maybe_prepare_first_time_step!(
    coupled_model::PR141_ESM.EarthSystemModel, Δt, callbacks)
    if coupled_model.clock.iteration == 0
        coupled_model.clock.last_Δt = Δt
        Oceananigans.TimeSteppers.reconcile_state!(coupled_model)
        Oceananigans.TimeSteppers.update_state!(coupled_model, callbacks)
    end
    return nothing
end

@inline pr141_legacy_interface_flux(FT) =
    ClimaSeaIce.ConductiveFlux(FT; conductivity = convert(FT, PR141_LEGACY_INTERFACE_CONDUCTIVITY))

function PR141_IC.default_ai_temperature(sea_ice::Simulation{<:ClimaSeaIce.SeaIceModel})
    thermodynamics = sea_ice.model.ice_thermodynamics
    if thermodynamics isa CSIT.ColumnEnergyThermodynamics
        return PR141_IC.SkinTemperature(pr141_legacy_interface_flux(eltype(sea_ice.model.grid)))
    end

    # Preserve the frozen-baseline implementation for slab thermodynamics.
    ice_flux = thermodynamics.internal_heat_flux
    snow_thermo = sea_ice.model.snow_thermodynamics
    internal_flux = isnothing(snow_thermo) ? ice_flux :
                    CSIT.IceSnowConductiveFlux(snow_thermo.internal_heat_flux.conductivity,
                                                ice_flux.conductivity)
    return PR141_IC.SkinTemperature(internal_flux)
end

function PR141_IC.ThreeEquationHeatFlux(sea_ice::Simulation{<:ClimaSeaIce.SeaIceModel},
                                         FT::DataType = Oceananigans.defaults.FloatType;
                                         heat_transfer_coefficient = 0.0095,
                                         salt_transfer_coefficient = heat_transfer_coefficient / 35,
                                         friction_velocity = convert(FT, 0.002))
    thermodynamics = sea_ice.model.ice_thermodynamics
    if thermodynamics isa CSIT.ColumnEnergyThermodynamics
        # `temperature[:, :, 1]` is the physical ocean-side cell of the
        # PR141 column and satisfies the legacy AbstractField interface.
        return PR141_IC.ThreeEquationHeatFlux(
            pr141_legacy_interface_flux(FT), thermodynamics.fields.temperature,
            convert(FT, heat_transfer_coefficient),
            convert(FT, salt_transfer_coefficient), friction_velocity)
    end

    conductive_flux = thermodynamics.internal_heat_flux
    ice_temperature = thermodynamics.top_surface_temperature
    return PR141_IC.ThreeEquationHeatFlux(conductive_flux, ice_temperature,
                                           convert(FT, heat_transfer_coefficient),
                                           convert(FT, salt_transfer_coefficient), friction_velocity)
end

# The frozen atmosphere--sea-ice interface stores the slab top temperature as
# a field. For a PR141 column, expose the physical top layer through the same
# 2-D indexing contract used by its GPU flux kernel.
function PR141_IC.atmosphere_sea_ice_interface(grid,
                                                atmosphere,
                                                sea_ice::Simulation{<:ClimaSeaIce.SeaIceModel},
                                                ai_flux_formulation,
                                                temperature_formulation,
                                                velocity_formulation)
    fluxes = PR141_IC.AtmosphereSeaIceFluxes(grid)
    humidity_formulation = PR141_IC.ImpureSaturationSpecificHumidity(
        NumericalEarth.EarthSystemModels.AtmosphericThermodynamics.Ice())
    properties = PR141_IC.InterfaceProperties(humidity_formulation,
                                               temperature_formulation,
                                               velocity_formulation)
    thermodynamics = sea_ice.model.ice_thermodynamics
    interface_temperature = thermodynamics isa CSIT.ColumnEnergyThermodynamics ?
                            PR141TopLayerTemperature(thermodynamics.fields.temperature) :
                            thermodynamics.top_surface_temperature
    return PR141_IC.AtmosphereInterface(fluxes, ai_flux_formulation,
                                        interface_temperature, properties)
end

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

@inline function CSIT.column_requested_surface_energy_flux(boundary::CSIT.MeltingLimitedSurfaceFlux{F},
                                                            i,
                                                            j) where
                                                            {F <: Union{Oceananigans.Fields.AbstractField, AbstractArray}}
    # NumericalEarth reports positive atmosphere--ice flux as cooling out of
    # the ice. The column's top boundary convention is positive into the ice.
    return -pr141_boundary_flux_value(boundary.flux, i, j)
end

@inline function CSIT.column_boundary_energy_flux(boundary::CSIT.PrescribedEnergyFlux{F},
                                                  i, j, k, grid, fields, relation, Δt) where
                                                  {F <: Union{Oceananigans.Fields.AbstractField, AbstractArray}}
    # NumericalEarth reports positive ocean--ice flux into the ice, whereas
    # the column's lower-boundary convention is positive out of the column.
    return -pr141_boundary_flux_value(boundary.flux, i, j)
end

@inline function CSIT.column_boundary_energy_flux(boundary::CSIT.MeltingLimitedSurfaceFlux{F},
                                                  i, j, k, grid, fields, relation, Δt) where
                                                  {F <: Union{Oceananigans.Fields.AbstractField, AbstractArray}}
    Δz = CSIT.current_column_cell_thickness(i, j, k, grid)
    E = @inbounds fields.internal_energy[i, j, k]
    S = @inbounds fields.bulk_salinity[i, j, k]
    requested_flux = -pr141_boundary_flux_value(boundary.flux, i, j)
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
    CSIT.initialize_column_vertical_metric!(sea_ice.model, thermodynamics)

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

    # This NumericalEarth convenience constructor accepts the ocean first and
    # builds the EarthSystemModel component ordering internally.
    return ESM.OceanSeaIceModel(ocean, sea_ice; atmosphere, radiation, land, interfaces)
end
