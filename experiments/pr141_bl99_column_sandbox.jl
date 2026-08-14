"""
Minimal CPU sandbox for PR141 BL99 column thermodynamics.

This is deliberately a single horizontal sea-ice cell with the same eight
vertical layers, thermodynamic relation, conductivity, moving metric, and
Hibler concentration update as the ORCA1 PR141 path. It removes the coupled
ocean/atmosphere, ORCA grid, GPU, and file staging so that a single forcing
mechanism can be tested in seconds on a laptop.

Examples
========

    # The initialized column gradient alone must not create ice.
    julia --project=. experiments/pr141_bl99_column_sandbox.jl open_water_gradient

    # A small positive ocean freezing flux should create thin, partial ice
    # without triggering column-gradient growth.
    julia --project=. experiments/pr141_bl99_column_sandbox.jl edge_freezing

    # Existing consolidated ice exercises the column conductive contribution.
    julia --project=. experiments/pr141_bl99_column_sandbox.jl consolidated_ice

Optional environment variables:

    PR141_SANDBOX_DAYS=30 PR141_SANDBOX_BOTTOM_FLUX=2.0 julia ... edge_freezing

Positive lower-boundary flux grows ice, matching the column Stefan convention.
"""

using ClimaSeaIce
using Oceananigans
using Oceananigans.Fields: interior, set!
using Oceananigans.Grids: MutableVerticalDiscretization
using Oceananigans.Units: days, minutes

const CSIT = ClimaSeaIce.SeaIceThermodynamics
const ice_layers = 8
const dt = 20minutes

scenario = isempty(ARGS) ? "edge_freezing" : only(ARGS)
scenario in ("open_water_gradient", "edge_freezing", "consolidated_ice") ||
    error("scenario must be open_water_gradient, edge_freezing, or consolidated_ice")

days_to_run = parse(Int, get(ENV, "PR141_SANDBOX_DAYS", "5"))
default_bottom_flux = scenario == "edge_freezing" ? 2.0 : 0.0
bottom_flux = parse(Float64, get(ENV, "PR141_SANDBOX_BOTTOM_FLUX", string(default_bottom_flux)))

grid = RectilinearGrid(size = (1, 1, ice_layers),
                       x = (0, 1),
                       y = (0, 1),
                       z = MutableVerticalDiscretization((0, 1)),
                       topology = (Bounded, Bounded, Bounded))

relation = CSIT.FixedSalinityBrinePocketEnergyRelation(Float64)
thermodynamics = CSIT.prescribed_salinity_enthalpy_thermodynamics(
    grid;
    relation,
    salinity_profile = 0.0,
    energy_transport = CSIT.ConductiveTemperatureTransport(
        conductivity = CSIT.MaykutUntersteinerConductivity(Float64)),
    boundary_conditions = CSIT.ColumnBoundaryConditions(
        top = CSIT.MeltingLimitedSurfaceFlux(flux = 0.0),
        bottom = CSIT.PrescribedEnergyFlux(flux = bottom_flux)),
)

# This is the deliberately non-equilibrated profile used during PR141 ORCA
# construction. The sandbox therefore catches accidental use of this gradient
# in open water, the source of the previous runaway.
set!(thermodynamics;
     bulk_salinity = 0.0,
     temperature = (x, y, z) -> -2 + (-10 + 2) * z)

model = SeaIceModel(grid;
                    ice_thermodynamics = thermodynamics,
                    phase_transitions = relation.phase_transitions,
                    top_heat_flux = 0,
                    bottom_heat_flux = 0,
                    ice_consolidation_thickness = 0.05)

if scenario == "consolidated_ice"
    set!(model, h = 1.0, ℵ = 1.0)
else
    set!(model, h = 0.0, ℵ = 0.0)
end
CSIT.initialize_column_vertical_metric!(model, thermodynamics)

scalar(field) = only(interior(field))

function report(day)
    h = scalar(model.ice_thickness)
    concentration = scalar(model.ice_concentration)
    basal_residual = scalar(thermodynamics.auxiliary.basal_stefan_residual_flux)
    @info "PR141 BL99 local column" scenario day h concentration basal_residual
end

println("day,h_m,siconc,basal_stefan_flux_W_m2")
report(0)
println("0,$(scalar(model.ice_thickness)),$(scalar(model.ice_concentration)),0")

steps_per_day = Int(days / dt)
for step in 1:(days_to_run * steps_per_day)
    CSIT.thermodynamic_time_step!(model, thermodynamics, nothing, dt)

    if step % steps_per_day == 0
        day = step ÷ steps_per_day
        report(day)
        println("$day,$(scalar(model.ice_thickness)),$(scalar(model.ice_concentration)),$(scalar(thermodynamics.auxiliary.basal_stefan_residual_flux))")
    end
end
