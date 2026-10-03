# Synthetic fixed-thickness column: no forcing files, ocean model, or snow.
# Exchange coefficients and atmospheric state are held fixed during each solve.
using Oceananigans: RectilinearGrid, Bounded, Field, Center
using ClimaSeaIce.SeaIceThermodynamics:
    SeaIceColumnDiscretization, FixedSalinityBrinePocketEnergyRelation,
    ConductiveTemperatureTransport, MeltingConstrainedFluxBalance, FluxBoundary,
    FluxFunction, column_energy_time_step!, prescribed_salinity_enthalpy_thermodynamics
using Oceananigans.Fields: interior, ConstantField, set!
using Oceananigans.TimeSteppers: Clock
using Oceananigans.Operators: Δzᶜᶜᶜ

const SYNTHETIC_AIR = (temperature=-35.0, relative_humidity=0.8, pressure=101325.0,
                       sensible_coefficient=25.0, mass_coefficient=25.0 / 1005.0,
                       emissivity=0.97, downward_longwave=180.0)

# Clausius–Clapeyron over ice, with constant sublimation latent heat.
function ice_humidity(T, pressure)
    Tk = T + 273.15
    e = 611.2 * exp(2.834e6 / 461.5 * (1 / 273.15 - 1 / Tk))
    return 0.622 * e / (pressure - 0.378 * e)
end

# Upward-positive flux, in W m^-2; T and air.temperature are in degrees Celsius.
function atmospheric_heat_flux(T, air=SYNTHETIC_AIR)
    q = ice_humidity(T, air.pressure)
    qa = air.relative_humidity * ice_humidity(air.temperature, air.pressure)
    sensible = air.sensible_coefficient * (T - air.temperature)
    latent = air.mass_coefficient * 2.834e6 * (q - qa)
    radiation = air.emissivity * (5.670374419e-8 * (T + 273.15)^4 - air.downward_longwave)
    return sensible + latent + radiation
end

surface_feedback_flux(i, j, grid, T, clock, fields, air) = atmospheric_heat_flux(T, air)

function nonlinear_surface_feedback(mode=:live; Δt=600.0, steps=6, air=SYNTHETIC_AIR)
    grid = RectilinearGrid(Float64; size=(1, 1, 8), x=(0, 1), y=(0, 1),
        z=SeaIceColumnDiscretization((0, 1.3)), topology=(Bounded, Bounded, Bounded))
    ice = prescribed_salinity_enthalpy_thermodynamics(grid;
        relation=FixedSalinityBrinePocketEnergyRelation(Float64), salinity_profile=0.0,
        energy_transport=ConductiveTemperatureTransport(conductivity=2.0),
        heat_boundary_conditions=(top=MeltingConstrainedFluxBalance(), bottom=FluxBoundary()))
    set!(ice; bulk_salinity=4.0, temperature=-5.0)
    Qref = Field{Center, Center, Nothing}(grid)
    flux = if mode == :lagged
        Qref
    elseif mode == :live
        FluxFunction(surface_feedback_flux; parameters=air, top_temperature_dependent=true)
    else
        throw(ArgumentError("Choose lagged or live"))
    end
    clock = Clock(time=0.0)
    Δz = Δzᶜᶜᶜ(1, 1, 8, grid)
    energy() = sum(interior(ice.fields.internal_energy)) * Δz
    history = NamedTuple[]
    Ts = ice.auxiliary.surface_temperature[1, 1, 1]
    push!(history, (; step=0, minutes=0.0, Ts, Q=NaN, surface_residual=NaN,
                    budget_residual=NaN, exchanged_budget_residual=NaN))
    for step in 1:steps
        q0 = atmospheric_heat_flux(Ts, air)
        set!(Qref, q0)
        E0 = energy()
        column_energy_time_step!(ice, (top=flux, bottom=0.0), clock, NamedTuple(), ConstantField(0.0), Δt)
        Ts = ice.auxiliary.surface_temperature[1, 1, 1]
        Ttop = ice.fields.temperature[1, 1, 8]
        Q = atmospheric_heat_flux(Ts, air)
        exchanged_Q = mode == :lagged ? q0 : Q
        surface_residual = Q - 4 / Δz * (Ttop - Ts)
        # Cold, insulated-base case: ΔE/Δt = -Q, with no melt or transmitted SW.
        budget_residual = (energy() - E0) / Δt + Q
        exchanged_budget_residual = (energy() - E0) / Δt + exchanged_Q
        push!(history, (; step, minutes=step * Δt / 60, Ts, Q, surface_residual,
                        budget_residual, exchanged_budget_residual))
        clock.time += Δt
    end
    return history
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("mode,step,minutes,Ts,Q,surface_residual,budget_residual,exchanged_budget_residual")
    for mode in (:lagged, :live), row in nonlinear_surface_feedback(mode)
        println(join((mode, values(row)...), ','))
    end
end
