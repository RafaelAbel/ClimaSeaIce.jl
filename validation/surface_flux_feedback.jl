# One cell, eight ice layers, and a synthetic atmosphere: no external data.
# Run with `live` (default) or `lagged` to reproduce the unstable coupling.
# Add `check` to require smooth evolution after the first adjustment.
using ClimaSeaIce, Oceananigans
using ClimaSeaIce.SeaIceThermodynamics:
    SeaIceColumnDiscretization, FixedSalinityBrinePocketEnergyRelation,
    ConductiveTemperatureTransport, MaykutUntersteinerConductivity,
    MeltingConstrainedFluxBalance, IceWaterThermalEquilibrium, FluxFunction,
    prescribed_salinity_enthalpy_thermodynamics
using Oceananigans.Fields: set!
using Oceananigans.TimeSteppers: time_step!

# Upward heat loss to air at -48 C, with a 25 W m^-2 K^-1 exchange coefficient.
feedback_flux(T) = 25 * (T + 48)

function surface_flux_feedback(mode; Δt=600.0, steps=5, verbose=true)
    grid = RectilinearGrid(Float64; size=(1, 1, 8), x=(0, 1), y=(0, 1),
                          z=SeaIceColumnDiscretization((0, 1)),
                          topology=(Bounded, Bounded, Bounded))
    relation = FixedSalinityBrinePocketEnergyRelation(Float64)
    ice = prescribed_salinity_enthalpy_thermodynamics(grid;
        relation, salinity_profile=0.0,
        energy_transport=ConductiveTemperatureTransport(
            conductivity=MaykutUntersteinerConductivity(Float64)),
        heat_boundary_conditions=(top=MeltingConstrainedFluxBalance(),
                                  bottom=IceWaterThermalEquilibrium(salinity=34.0)))
    Qref = Field{Center, Center, Nothing}(grid)
    set!(Qref, feedback_flux(0.0))
    flux = if mode == :lagged
        Qref
    elseif mode == :live
        FluxFunction((i, j, grid, T, clock, fields) -> feedback_flux(T);
                     top_temperature_dependent=true)
    else
        throw(ArgumentError("Choose lagged or live"))
    end
    model = SeaIceModel(grid; ice_thermodynamics=ice,
        phase_transitions=relation.phase_transitions,
        top_heat_flux=flux, bottom_heat_flux=0.0, timestepper=:ForwardEuler,
        ice_consolidation_thickness=0.05)
    set!(model; h=1.3, ℵ=1.0, u=0.0, v=0.0)
    set!(ice; bulk_salinity=4.0, temperature=-5.0)
    history = Float64[]
    for step in 0:steps
        Ts = ice.auxiliary.surface_temperature[1, 1, 1]
        push!(history, Ts)
        verbose && println((mode, step, surface_temperature=Ts))
        step == steps && break
        # Mimic a coupler refreshing its fields once per ice step.
        set!(Qref, feedback_flux(Ts))
        time_step!(model, Δt)
    end
    return history
end

if abspath(PROGRAM_FILE) == @__FILE__
    mode = Symbol(isempty(ARGS) ? "live" : ARGS[1])
    temperatures = surface_flux_feedback(mode)
    if "check" in ARGS
        @assert all(isfinite, temperatures)
        @assert maximum(abs.(diff(temperatures[2:end]))) < 5 "Surface temperature oscillates after the first adjustment"
    end
end
