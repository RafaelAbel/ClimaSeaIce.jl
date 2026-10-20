# A single-cell balance built from the first failure in the 1° Arctic replay:
# 2006 model hour 1840.167, cell (33, 44). It uses the measured meteorology,
# snow thickness, top-layer temperature, and ice thickness, without ORCA1 or
# regional dynamics. The previous ice skin is a representative melting value.
module RegionalThinSnowSurfaceFailure

using ClimaSeaIce, Oceananigans, Test
using ClimaSeaIce.SeaIceThermodynamics: SeaIceColumnDiscretization
using ClimaSeaIce.SeaIceThermodynamics.HeatBoundaryConditions: FluxFunction, getflux
using Oceananigans.Architectures: architecture
using Oceananigans.Fields: Field, set!
using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBoundary
using Oceananigans.TimeSteppers: Clock
using Oceananigans.Utils: launch!

const SI = ClimaSeaIce.SeaIceThermodynamics
const Ta = 277.728916422526
const qair = 0.0048475598062699046
const p = 103132.7359375
const speed = hypot(1.986268457770367, -0.03793264776467879)
const lw = 339.66806640625
const sw = 57.385873349507946
const hs = 0.00023206826032621405
const h = 1.0537630538084337
const Ttop = -0.2160028923486799
const Tprevious = -0.216
const conductance = 2 * 0.1 / (h / 8)

function atmospheric_flux(T)
    eice = 611.2 * exp(22.46 * T / (272.62 + T))
    qsat = 0.622 * eice / (p - 0.378 * eice)
    sensible = 1.3 * 1004.0 * 1.3e-3 * speed * (T + 273.15 - Ta)
    latent = 1.3 * 2.83e6 * 1.3e-3 * speed * (qsat - qair)
    longwave = 0.97 * 5.670374419e-8 * (T + 273.15)^4 - lw
    shortwave = -0.2 * sw
    return sensible + latent + longwave + shortwave
end

grid = RectilinearGrid(Float64; size=(1, 1, 8), x=(0, 1), y=(0, 1),
    z=SeaIceColumnDiscretization((0, 1)), topology=(Bounded, Bounded, Bounded))
snow_thickness = Field{Center, Center, Nothing}(grid)
snow_skin = Field{Center, Center, Nothing}(grid)
set!(snow_thickness, hs)
atmosphere = FluxFunction((i, j, grid, T, clock, fields) -> atmospheric_flux(T);
    top_temperature_dependent=true)
snow_top = SI.SnowColumnTopFlux(atmosphere, snow_thickness, 0.31, 330.0,
    334000.0, snow_skin, 60.0)
clock = Clock(time=1840.1666666666667 * 3600)
fields = NamedTuple()

balance(Tice) = getflux(snow_top, 1, 1, grid, Tice, clock, fields) -
                conductance * (Ttop - Tice)

secant = SI.find_zero(balance,
    SI.SecantMethod{Float64}(Tprevious + 1, Tprevious), SI.CompactSolution())
println("original secant: root=$(secant.root), converged=$(secant.converged), residual=$(balance(secant.root)) W/m²")

Tice = SI.column_surface_temperature_balance(1, 1, grid, Tprevious,
    conductance, Ttop, snow_top, clock, fields)
Tice = min(Tice, Ttop) # representative ice melting constraint
Ts, _, _ = SI.snow_column_fluxes(snow_top, 1, 1, grid, Tice, clock, fields)
snow_residual = abs((0.31 / hs) * (Tice - Ts) - atmospheric_flux(Ts))
println("ice skin=$Tice °C, snow skin=$Ts °C, snow residual=$snow_residual W/m²")

# A second guard keeps the snow solve bracketed even if another caller gives
# it an ice surface colder than the original fixed -100°C snow bound.
extreme_ice_skin = -234.1084488115814
extreme_snow_skin, _, _ = SI.snow_column_fluxes(snow_top, 1, 1, grid,
    extreme_ice_skin, clock, fields)
extreme_residual = abs((0.31 / hs) * (extreme_ice_skin - extreme_snow_skin) -
                       atmospheric_flux(extreme_snow_skin))

@testset "Captured thin snow surface balance" begin
    @test isfinite(Tice) && -100 < Tice <= Ttop
    @test abs(balance(Tice)) < 100 # constrained melting leaves a latent-energy residual
    @test snow_residual < 1e-5
    @test extreme_residual < 1e-5
end

# The regional grid also contains masked land and open water. Neither has an
# ice surface energy balance, even though the diagnostic kernel visits them.
underlying = RectilinearGrid(Float64; size=(2, 1, 8), x=(0, 2), y=(0, 1),
    z=SeaIceColumnDiscretization((0, 1)), topology=(Bounded, Bounded, Bounded))
land(x, y, z) = x < 1
empty_grid = ImmersedBoundaryGrid(underlying, GridFittedBoundary(land))
column_z = SI.sea_ice_discretization(empty_grid)
column_z.hsⁿ[2, 1, 1] = 0.0
column_z.hbⁿ[2, 1, 1] = 0.0
thermal_fields = SI.column_thermodynamic_fields(empty_grid)
auxiliary = SI.column_auxiliary_fields(empty_grid)
set!(thermal_fields.temperature, -5.0)
set!(thermal_fields.bulk_salinity, 4.0)
set!(auxiliary.surface_temperature, -3.0)
set!(auxiliary.thermal_conductivity, 0.1)
unused_flux = FluxFunction((i, j, grid, T, clock, fields) -> NaN;
    top_temperature_dependent=true)
relation = SI.FixedSalinityBrinePocketEnergyRelation(Float64)
launch!(architecture(empty_grid), empty_grid, :xy,
    SI._update_column_surface_temperature!, auxiliary, thermal_fields,
    empty_grid, unused_flux, relation, clock, NamedTuple())

@testset "No ice surface solve on land or open water" begin
    @test auxiliary.surface_temperature[1, 1, 1] == -5.0 # masked land
    @test auxiliary.surface_temperature[2, 1, 1] == -5.0 # zero-height column
end

end # module
