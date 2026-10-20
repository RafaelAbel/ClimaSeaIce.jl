using ClimaSeaIce, Oceananigans, Printf, Serialization, Statistics, TOML
using Oceananigans: prognostic_state, restore_prognostic_state!
using ClimaSeaIce.SeaIceThermodynamics
using ClimaSeaIce.SeaIceThermodynamics.HeatBoundaryConditions: FluxFunction
using Oceananigans.OrthogonalSphericalShellGrids: RotatedLatitudeLongitudeGrid
using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBoundary
using Oceananigans.Coriolis: HydrostaticSphericalCoriolis
using Oceananigans.Fields: Field, set!, interior, ZeroField
using Oceananigans.Operators: Azᶜᶜᶜ, Δxᶠᶜᶜ, Δyᶜᶠᶜ
using Oceananigans.TimeSteppers: update_state!, tick!

const N = 44
const NZ = 8
const INPUT = joinpath(@__DIR__, "..", "arctic-thermo", "input")
const TF = -1.8
const RHOCP = 1025.6 * 3995.6
const OCEAN_DEPTH = 50.0
const QB_COEFFICIENT = 10.0
const AIR_DENSITY = 1.3
const AIR_DRAG = 1.3e-3

function read_f32(name, dims...; complete=true)
    a = Array{Float32}(undef, dims...)
    open(joinpath(INPUT, name * ".f32")) do io
        read!(io, a)
        complete && !eof(io) && error("Extra bytes in $name")
    end
    all(isfinite, a) || error("Nonfinite values in $name")
    return a
end

struct Atmosphere{A}
    tas::A
    huss::A
    psl::A
    uas::A
    vas::A
    rlds::A
    rsds::A
    prsn::A
    wet::Matrix{Float32}
end

@inline function interp(a, i, j, t)
    f = clamp(t / 10800.0, 0.0, size(a, 3) - 1.0)
    k = min(floor(Int, f) + 1, size(a, 3) - 1)
    w = f - (k - 1)
    return (1 - w) * @inbounds(a[i,j,k]) + w * @inbounds(a[i,j,k+1])
end

# Positive heat flux is upward, away from the ice or snow surface.
@inline function surface_flux(a::Atmosphere, i, j, Ts, t; albedo=0.65)
    a.wet[i,j] > 0.5 || return 0.0
    Ta = interp(a.tas,i,j,t)
    qair = interp(a.huss,i,j,t)
    p = interp(a.psl,i,j,t)
    speed = hypot(interp(a.uas,i,j,t), interp(a.vas,i,j,t))
    Tsk = Ts + 273.15
    eice = 611.2 * exp(22.46 * Ts / (272.62 + Ts))
    qsat = 0.622 * eice / (p - 0.378 * eice)
    sensible = AIR_DENSITY * 1004.0 * AIR_DRAG * speed * (Tsk - Ta)
    latent = AIR_DENSITY * 2.83e6 * AIR_DRAG * speed * (qsat - qair)
    longwave = 0.97 * 5.670374419e-8 * Tsk^4 - interp(a.rlds,i,j,t)
    shortwave = -(1 - albedo) * interp(a.rsds,i,j,t)
    return sensible + latent + longwave + shortwave
end

struct TopFlux{A,B}
    atmosphere::A
    ocean_temperature::B
end
@inline function (f::TopFlux)(i,j,grid,Ts,clock,fields)
    if fields.ℵ[i,j,1] <= 0 && f.ocean_temperature[i,j] > TF + 0.001
        return 0.0
    end
    albedo = fields.hs[i,j,1] > 1e-8 ? 0.8 : 0.65
    return surface_flux(f.atmosphere,i,j,Ts,clock.time;albedo)
end

struct BottomFlux{A}
    temperature::A
    wet::Matrix{Float32}
end
@inline (f::BottomFlux)(i,j,grid,Tb,clock,fields) =
    f.wet[i,j] > 0.5 ? QB_COEFFICIENT * max(f.temperature[i,j] - TF, 0.0) : 0.0

@inline position(lon, lat) = (cosd(lat)*cosd(lon), cosd(lat)*sind(lon), sind(lat))

# Project a geographic east/north vector onto the local grid-face tangent.
# The tangent comes from actual Oceananigans geographic node coordinates,
# avoiding pole and longitude-wrap ambiguities in a finite-difference angle.
function face_direction(base, i, j, axis)
    if axis == :u
        i0, i1 = clamp(i-1,1,N), clamp(i,1,N)
        i0 == i1 && ((i0,i1) = i == 1 ? (1,2) : (N-1,N))
        p0 = position(base.λᶜᶜᵃ[i0,j], base.φᶜᶜᵃ[i0,j])
        p1 = position(base.λᶜᶜᵃ[i1,j], base.φᶜᶜᵃ[i1,j])
        lon, lat = base.λᶠᶜᵃ[i,j], base.φᶠᶜᵃ[i,j]
    else
        j0, j1 = clamp(j-1,1,N), clamp(j,1,N)
        j0 == j1 && ((j0,j1) = j == 1 ? (1,2) : (N-1,N))
        p0 = position(base.λᶜᶜᵃ[i,j0], base.φᶜᶜᵃ[i,j0])
        p1 = position(base.λᶜᶜᵃ[i,j1], base.φᶜᶜᵃ[i,j1])
        lon, lat = base.λᶜᶠᵃ[i,j], base.φᶜᶠᵃ[i,j]
    end
    d = ntuple(n -> p1[n]-p0[n], 3)
    east = -sind(lon)*d[1] + cosd(lon)*d[2]
    north = -sind(lat)*cosd(lon)*d[1] - sind(lat)*sind(lon)*d[2] + cosd(lat)*d[3]
    norm = hypot(east,north)
    norm > 0 || error("Degenerate face direction at ($i,$j,$axis)")
    return east/norm, north/norm
end

function wind_directions(base)
    ue = Matrix{Float64}(undef,N+1,N); un = similar(ue)
    ve = Matrix{Float64}(undef,N,N+1); vn = similar(ve)
    for j in 1:N, i in 1:N+1
        ue[i,j],un[i,j] = face_direction(base,i,j,:u)
    end
    for j in 1:N+1, i in 1:N
        ve[i,j],vn[i,j] = face_direction(base,i,j,:v)
    end
    return (;ue,un,ve,vn)
end

function update_wind_stress!(u_stress, v_stress, atmosphere, directions, wet, t)
    u = view(interior(u_stress),:,:,1)
    v = view(interior(v_stress),:,:,1)
    maxstress = 0.0
    for j in 1:N, i in 1:N+1
        l,r = clamp(i-1,1,N),clamp(i,1,N)
        if i == 1 || i == N+1 || !(wet[l,j] && wet[r,j])
            u[i,j] = 0.0
        else
            east = (interp(atmosphere.uas,l,j,t)+interp(atmosphere.uas,r,j,t))/2
            north = (interp(atmosphere.vas,l,j,t)+interp(atmosphere.vas,r,j,t))/2
            speed = hypot(east,north)
            # This API subtracts top stress in its momentum tendency.
            u[i,j] = -AIR_DENSITY*AIR_DRAG*speed*
                     (directions.ue[i,j]*east+directions.un[i,j]*north)
            maxstress = max(maxstress,abs(u[i,j]))
        end
    end
    for j in 1:N+1, i in 1:N
        b,tj = clamp(j-1,1,N),clamp(j,1,N)
        if j == 1 || j == N+1 || !(wet[i,b] && wet[i,tj])
            v[i,j] = 0.0
        else
            east = (interp(atmosphere.uas,i,b,t)+interp(atmosphere.uas,i,tj,t))/2
            north = (interp(atmosphere.vas,i,b,t)+interp(atmosphere.vas,i,tj,t))/2
            speed = hypot(east,north)
            v[i,j] = -AIR_DENSITY*AIR_DRAG*speed*
                     (directions.ve[i,j]*east+directions.vn[i,j]*north)
            maxstress = max(maxstress,abs(v[i,j]))
        end
    end
    return maxstress
end

function update_snowfall!(snowfall, atmosphere, wet, t)
    rate=view(interior(snowfall),:,:,1)
    for j=1:N,i=1:N
        rate[i,j]=wet[i,j] ? interp(atmosphere.prsn,i,j,t) : 0.0
    end
    return nothing
end

function build(hours)
    wet_f32 = read_f32("wet",N,N)
    wet = wet_f32 .> 0.5
    h0 = read_f32("h",N,N)
    a0 = read_f32("concentration",N,N)
    To = Float64.(read_f32("ocean_temperature",N,N))
    frames = clamp(ceil(Int,hours*3600/10800)+1,2,2921)
    atmosphere = Atmosphere((read_f32(s,N,N,frames;complete=frames==2921) for s in
        ("tas","huss","psl","uas","vas","rlds","rsds","prsn"))...,wet_f32)
    base = RotatedLatitudeLongitudeGrid(CPU(),Float64;size=(N,N,NZ),
        longitude=(158,202),latitude=(-22,22),north_pole=(0,0),
        z=SeaIceColumnDiscretization((0,1)),halo=(3,3,3),
        topology=(Bounded,Bounded,Bounded))
    lon = read_f32("longitude",N,N); lat = read_f32("latitude",N,N)
    maximum(abs.(lon.-[base.λᶜᶜᵃ[i,j] for i=1:N,j=1:N])) < 1e-4 || error("Longitude mismatch")
    maximum(abs.(lat.-[base.φᶜᶜᵃ[i,j] for i=1:N,j=1:N])) < 1e-4 || error("Latitude mismatch")
    mask = Field{Center,Center,Center}(base,Bool)
    set!(mask,repeat(reshape(.!wet,N,N,1),1,1,NZ))
    grid = ImmersedBoundaryGrid(base,GridFittedBoundary(mask))
    directions = wind_directions(base)
    u_stress = Field{Face,Center,Nothing}(grid)
    v_stress = Field{Center,Face,Nothing}(grid)
    top_stress = (u=u_stress,v=v_stress)
    bottom_stress = SemiImplicitStress(Float64;uₑ=ZeroField(Float64),
        vₑ=ZeroField(Float64),ρₑ=1025.6,Cᴰ=3.24e-3)
    dynamics = SeaIceMomentumEquation(grid;coriolis=HydrostaticSphericalCoriolis(),
        rheology=ElastoViscoPlasticRheology(Float64),
        solver=SplitExplicitSolver(grid;substeps=150),
        top_momentum_stress=top_stress,bottom_momentum_stress=bottom_stress,
        free_drift=StressBalanceFreeDrift(top_stress,bottom_stress))
    relation = FixedSalinityBrinePocketEnergyRelation(Float64)
    thermo = prescribed_salinity_enthalpy_thermodynamics(grid;relation,
        salinity_profile=0.0,
        energy_transport=ConductiveTemperatureTransport(
            conductivity=MaykutUntersteinerConductivity(Float64)),
        heat_boundary_conditions=(top=MeltingConstrainedFluxBalance(),
            bottom=IceWaterThermalEquilibrium(salinity=35.0)))
    snow = snow_slab_thermodynamics(grid)
    snowfall=Field{Center,Center,Nothing}(grid)
    set!(snowfall,0.0)
    model = SeaIceModel(grid;dynamics,ice_thermodynamics=thermo,
        snow_thermodynamics=snow,phase_transitions=relation.phase_transitions,
        ice_consolidation_thickness=0.05,advection=IncrementalRemapping(),
        top_heat_flux=FluxFunction(TopFlux(atmosphere,To);top_temperature_dependent=true),
        bottom_heat_flux=FluxFunction(BottomFlux(To,wet_f32)),
        snowfall,timestepper=:ForwardEuler)
    hinit = Float64.(ifelse.(h0 .> 0,h0,0.05f0))
    ainit = Float64.(a0 .* wet)
    set!(model;h=reshape(hinit,N,N,1),ℵ=reshape(ainit,N,N,1),u=0.0,v=0.0)
    # No snow analysis is present in the prepared data. A capped initial
    # layer preserves positive freeboard and allows the snow coupling to run.
    hs0 = [ainit[i,j] > 0 ? min(0.20,0.20*hinit[i,j],
                                 0.8*(1025.6-900.0)/330.0*hinit[i,j]) : 0.0
           for i=1:N,j=1:N]
    set!(model;hs=reshape(hs0,N,N,1))
    set!(thermo;bulk_salinity=4.0,temperature=TF-2.0)
    for k in 1:NZ
        interior(thermo.fields.temperature)[:,:,k] .= TF-3.0*(k-0.5)/NZ
    end
    ClimaSeaIce.SeaIceThermodynamics.compute_column_internal_energy!(thermo)
    ClimaSeaIce.SeaIceThermodynamics.compute_column_thermodynamic_diagnostics!(thermo)
    area = [Azᶜᶜᶜ(i,j,NZ,grid) for i=1:N,j=1:N]
    return (;model,thermo,snow,wet,To,area,atmosphere,directions,u_stress,v_stress,hs0)
end

function metrics(s)
    m,t=s.model,s.thermo
    h=Array(interior(m.ice_thickness))[:,:,1]
    a=Array(interior(m.ice_concentration))[:,:,1]
    hs=Array(interior(m.snow_thickness))[:,:,1]
    T=Array(interior(t.fields.temperature))
    E=Array(interior(t.fields.internal_energy))
    snow_skin=Array(interior(s.snow.top_surface_temperature))[:,:,1]
    ice_skin=Array(interior(t.auxiliary.surface_temperature))[:,:,1]
    u=Array(interior(m.velocities.u)); v=Array(interior(m.velocities.v))
    all(all(isfinite,x) for x in (h,a,hs,T,E,snow_skin,ice_skin,u,v,s.To)) || error("Nonfinite state")
    all(0 .<= a .<= 1.000001) || error("Concentration out of bounds")
    all(0 .<= h .< 6) || error("Ice thickness reached the regional 6 m guard")
    all(0 .<= hs .< 2) || error("Snow thickness out of bounds")
    all(-55 .< T .< 1) || error("Column temperature out of bounds")
    all(-3 .< s.To[s.wet] .< 15) || error("Ocean temperature out of bounds")
    active = s.wet .& (a .> 1e-10)
    z=s.model.grid.underlying_grid.z
    mismatch=maximum(abs.([z.hsⁿ[i,j,1]-z.hbⁿ[i,j,1]-h[i,j] for i=1:N,j=1:N][active]))
    residual=Array(interior(t.auxiliary.snow_surface_residual))[:,:,1]
    snowy=s.wet .& (hs .> 0) .& (a .> 1e-10)
    return (;h,a,hs,T,E,snow_skin,ice_skin,u,v,
        area=sum(a .* s.area .* s.wet),
        ice_volume=sum(a .* h .* s.area .* s.wet),
        snow_volume=sum(a .* hs .* s.area .* s.wet),
        hmax=maximum(h[active]),hsmax=maximum(hs[active]),
        Tmin=minimum(T[repeat(reshape(active,N,N,1),1,1,NZ)]),
        Tmax=maximum(T[repeat(reshape(active,N,N,1),1,1,NZ)]),
        snow_skin_max=any(snowy) ? maximum(snow_skin[snowy]) : 0.0,
        snow_residual=any(snowy) ? maximum(residual[snowy]) : 0.0,
        speed=max(maximum(abs,u),maximum(abs,v)),mismatch,
        ocean_min=minimum(s.To[s.wet]),ocean_max=maximum(s.To[s.wet]))
end

# This sea-ice model transports horizontally. Inactive columns can have zero
# vertical height, so the generic 3D timescale evaluates 0 / 0 there.
function horizontal_cfl(s, dt)
    grid = s.model.grid.underlying_grid
    u = interior(s.model.velocities.u)
    v = interior(s.model.velocities.v)
    cfl = 0.0
    for j in 1:N, i in 1:N
        if s.wet[i,j]
            rate = abs(u[i,j,1]) / Δxᶠᶜᶜ(i,j,1,grid) +
                   abs(v[i,j,1]) / Δyᶜᶠᶜ(i,j,1,grid)
            cfl = max(cfl, dt * rate)
        end
    end
    isfinite(cfl) || error("Nonfinite horizontal CFL")
    return cfl
end

function snapshot(path,s,d)
    open(path,"w") do io
        serialize(io,(time=s.model.clock.time,h=d.h,a=d.a,hs=d.hs,T=d.T,E=d.E,
            snow_skin=d.snow_skin,ice_skin=d.ice_skin,u=d.u,v=d.v,To=copy(s.To)))
    end
end

const RESTART_FORMAT_VERSION = 1

# Save all column diagnostics as well as the prognostic model state. The next
# nonlinear surface solve uses the previous surface temperatures as guesses.
function column_arrays(component)
    names = fieldnames(typeof(component))
    return NamedTuple{names}(Tuple(copy(getproperty(component, name).data) for name in names))
end

function restore_column_arrays!(component, saved)
    names = fieldnames(typeof(component))
    keys(saved) == names || error("Checkpoint column fields do not match this driver")
    for name in names
        destination = getproperty(component, name).data
        source = saved[name]
        axes(destination) == axes(source) || error("Checkpoint axes differ for $name")
        copyto!(destination, source)
    end
    return nothing
end

function save_restart_checkpoint(path, s, dt, before, accumulators, elapsed_wall_seconds)
    z = s.model.grid.underlying_grid.z
    checkpoint = (
        format_version = RESTART_FORMAT_VERSION,
        dt_seconds = dt,
        model_hour = s.model.clock.time / 3600,
        model_state = prognostic_state(s.model),
        column_grid = (hsⁿ=copy(z.hsⁿ), hbⁿ=copy(z.hbⁿ),
                       hs⁻=copy(z.hs⁻), hb⁻=copy(z.hb⁻)),
        column_fields = column_arrays(s.thermo.fields),
        column_auxiliary = column_arrays(s.thermo.auxiliary),
        ocean_temperature = copy(s.To),
        before = before,
        accumulators = accumulators,
        elapsed_wall_seconds = elapsed_wall_seconds,
    )
    temporary = path * ".partial"
    open(temporary, "w") do io
        serialize(io, checkpoint)
    end
    mv(temporary, path; force=true)
    return nothing
end

function restore_restart_checkpoint!(path, s, dt)
    checkpoint = open(deserialize, path)
    checkpoint.format_version == RESTART_FORMAT_VERSION || error("Unsupported restart format")
    checkpoint.dt_seconds == dt || error("Restart time step differs from checkpoint")
    size(checkpoint.ocean_temperature) == size(s.To) || error("Ocean slab shape differs")

    restore_prognostic_state!(s.model, checkpoint.model_state)
    z = s.model.grid.underlying_grid.z
    for name in keys(checkpoint.column_grid)
        destination = getproperty(z, name)
        source = checkpoint.column_grid[name]
        axes(destination) == axes(source) || error("Checkpoint column grid axes differ for $name")
        copyto!(destination, source)
    end
    restore_column_arrays!(s.thermo.fields, checkpoint.column_fields)
    restore_column_arrays!(s.thermo.auxiliary, checkpoint.column_auxiliary)
    copyto!(s.To, checkpoint.ocean_temperature)
    s.model.clock.time / 3600 == checkpoint.model_hour || error("Checkpoint clock differs")
    return checkpoint
end

function prepare_restart_output!(out, hour)
    csv = joinpath(out, "hourly.csv")
    isfile(csv) || error("Restart requires the original hourly.csv in $out")
    lines = readlines(csv)
    length(lines) >= 2 || error("Restart hourly.csv has no data")
    saved = filter(line -> !isempty(line) && parse(Float64, first(split(line, ','))) <= hour,
                   lines[2:end])
    length(saved) == round(Int, hour) || error("Hourly records do not reach checkpoint hour $hour")
    parse(Float64, first(split(last(saved), ','))) == hour || error("Last retained record is not the checkpoint hour")
    if length(saved) != length(lines) - 1
        temporary = csv * ".partial"
        open(temporary, "w") do io
            println(io, first(lines))
            foreach(line -> println(io, line), saved)
        end
        mv(temporary, csv; force=true)
    end
    for file in readdir(out)
        matched = match(r"^day_(\d+)\.bin$", file)
        if matched !== nothing && parse(Int, matched.captures[1]) * 24 > hour
            rm(joinpath(out, file))
        end
        matched = match(r"^checkpoint_hour_(\d+)\.bin$", file)
        if matched !== nothing && parse(Int, matched.captures[1]) > hour
            rm(joinpath(out, file))
        end
    end
    return nothing
end

# Inspect the first failed snow balance immediately after a model step. This
# diagnostic reads fields only, and is enabled late enough to keep the replay
# identical to the original integration through the first 70 model days.
function diagnose_snow_failure!(s, t, a_before, hs_before, out)
    t < 70 * 86400 && return nothing
    residual = Array(interior(s.thermo.auxiliary.snow_surface_residual))[:, :, 1]
    a_after = Array(interior(s.model.ice_concentration))[:, :, 1]
    hs_after = Array(interior(s.model.snow_thickness))[:, :, 1]
    bad_i = bad_j = 0
    largest = 0.1
    for j in 1:N, i in 1:N
        if s.wet[i,j] && a_after[i,j] > 1e-10 && hs_after[i,j] > 0
            r = residual[i,j]
            if !isfinite(r) || r > largest
                bad_i, bad_j, largest = i, j, r
            end
        end
    end
    bad_i == 0 && return nothing

    i, j = bad_i, bad_j
    ice_skin = Array(interior(s.thermo.auxiliary.surface_temperature))[:, :, 1]
    snow_skin = Array(interior(s.snow.top_surface_temperature))[:, :, 1]
    h_after = Array(interior(s.model.ice_thickness))[:, :, 1]
    temperature = Array(interior(s.thermo.fields.temperature))
    energy = Array(interior(s.thermo.fields.internal_energy))
    conductivity = s.snow.internal_heat_flux.conductivity
    albedo = hs_before[i,j] > 1e-8 ? 0.8 : 0.65
    q_atmosphere = surface_flux(s.atmosphere, i, j, snow_skin[i,j], t; albedo)
    report = Dict(
        "model_hour" => s.model.clock.time / 3600,
        "grid_i" => i, "grid_j" => j,
        "residual_W_m2" => largest,
        "ice_concentration_before_step" => a_before[i,j],
        "ice_concentration_after_step" => a_after[i,j],
        "snow_thickness_before_full_step_m" => hs_before[i,j],
        "snow_thickness_after_step_m" => hs_after[i,j],
        "ice_thickness_after_step_m" => h_after[i,j],
        "ice_surface_temperature_C" => ice_skin[i,j],
        "snow_surface_temperature_C" => snow_skin[i,j],
        "ice_top_layer_temperature_C" => temperature[i,j,NZ],
        "snow_conductivity_W_m_K" => conductivity,
        "atmospheric_flux_at_retained_snow_skin_W_m2" => q_atmosphere,
        "air_temperature_K" => interp(s.atmosphere.tas,i,j,t),
        "specific_humidity" => interp(s.atmosphere.huss,i,j,t),
        "surface_pressure_Pa" => interp(s.atmosphere.psl,i,j,t),
        "downwelling_longwave_W_m2" => interp(s.atmosphere.rlds,i,j,t),
        "downwelling_shortwave_W_m2" => interp(s.atmosphere.rsds,i,j,t),
        "wind_east_m_s" => interp(s.atmosphere.uas,i,j,t),
        "wind_north_m_s" => interp(s.atmosphere.vas,i,j,t),
    )
    open(joinpath(out, "first_snow_failure.toml"), "w") do io
        TOML.print(io, report; sorted=true)
    end
    open(joinpath(out, "first_snow_failure.bin"), "w") do io
        serialize(io, (;report, residual, a_before, hs_before, a_after,
                       hs_after, h_after, ice_skin, snow_skin, temperature,
                       energy, ocean_temperature=copy(s.To)))
    end
    @error "First snow surface balance failure" report
    failed_hour = report["model_hour"]
    error("Snow surface balance failed at model hour $failed_hour: $largest W/m²")
end

"""Advance the Forward Euler model and retain the surface state used by thermodynamics."""
function time_step_with_surface_state!(model, dt, capture_surface)
    # Match ClimaSeaIce's Forward Euler step. Dynamics changes snow and ice
    # before thermodynamics selects its surface flux and consolidated branch.
    model.clock.iteration == 0 && update_state!(model)
    ClimaSeaIce.compute_tendencies!(model, dt)
    ClimaSeaIce.SeaIceDynamics.time_step_momentum!(model, model.dynamics, dt)
    ClimaSeaIce.dynamic_time_step!(model, dt)
    surface = capture_surface ? (
        h=Array(interior(model.ice_thickness))[:, :, 1],
        a=Array(interior(model.ice_concentration))[:, :, 1],
        hs=Array(interior(model.snow_thickness))[:, :, 1]) : nothing
    ClimaSeaIce.SeaIceThermodynamics.thermodynamic_time_step!(
        model, model.ice_thermodynamics, model.snow_thermodynamics, dt)
    tick!(model.clock, dt)
    update_state!(model)
    return surface
end

function bare_surface_balance(s,d,dt,surface)
    z=s.model.grid.underlying_grid.z
    K=interior(s.thermo.auxiliary.thermal_conductivity)[:,:,NZ+1]
    Tm=ClimaSeaIce.SeaIceThermodynamics.melting_temperature(
        s.thermo.relation.phase_transitions.liquidus,4.0)
    frozen=0.0; melting=0.0; count=0
    for j=1:N,i=1:N
        if s.wet[i,j] && surface.a[i,j]>0 && d.a[i,j]>0 &&
           surface.hs[i,j]<=1e-8 && surface.h[i,j]>=0.05
            hprev=z.hs⁻[i,j,1]-z.hb⁻[i,j,1]
            hprev>0 || error("Nonpositive previous bare-ice column height")
            conductance=2*K[i,j]*NZ/hprev
            Ts=d.ice_skin[i,j]
            R=surface_flux(s.atmosphere,i,j,Ts,s.model.clock.time-dt;albedo=0.65)-
                conductance*(d.T[i,j,NZ]-Ts)
            if Ts<Tm-1e-5
                frozen=max(frozen,abs(R))
            else
                melting=max(melting,R)
            end
            count+=1
        end
    end
    return frozen,melting,count
end

function main()
    hours=parse(Float64,get(ENV,"PR165_HOURS","6"))
    dt=parse(Float64,get(ENV,"PR165_DT","60"))
    steps=round(Int,hours*3600/dt)
    abs(steps*dt-hours*3600)<1e-5 || error("Duration must divide time step")
    checkpoint_hours=parse(Int,get(ENV,"PR165_CHECKPOINT_INTERVAL_HOURS","1200"))
    checkpoint_steps=round(Int,checkpoint_hours*3600/dt)
    checkpoint_hours > 0 && checkpoint_steps*dt == checkpoint_hours*3600 ||
        error("Checkpoint interval must be positive and divide the time step")
    restart_path=get(ENV,"PR165_RESTART_CHECKPOINT","")
    out=length(ARGS)>0 ? abspath(ARGS[1]) : joinpath(@__DIR__,"regional_forced_output")
    isempty(restart_path) && isdir(out) && !isempty(readdir(out)) && error("Output exists: $out")
    mkpath(out)
    s=build(hours)
    if isempty(restart_path)
        before=metrics(s)
        snapshot(joinpath(out,"initial.bin"),s,before)
        ocean_initial=RHOCP*OCEAN_DEPTH*sum(s.To .* s.area .* s.wet)
        basal_integral=0.0
        ice_mass_flux_integral=0.0
        snow_mass_flux_integral=0.0
        snowfall_mass_integral=0.0
        maxstress=0.0
        max_snow_residual=0.0
        max_bare_frozen_residual=0.0
        max_bare_melting_violation=0.0
        started=time()
        first_step=1
    else
        checkpoint=restore_restart_checkpoint!(abspath(restart_path),s,dt)
        before=checkpoint.before
        ocean_initial=checkpoint.accumulators.ocean_initial
        basal_integral=checkpoint.accumulators.basal_integral
        ice_mass_flux_integral=checkpoint.accumulators.ice_mass_flux_integral
        snow_mass_flux_integral=checkpoint.accumulators.snow_mass_flux_integral
        snowfall_mass_integral=checkpoint.accumulators.snowfall_mass_integral
        maxstress=checkpoint.accumulators.maxstress
        max_snow_residual=checkpoint.accumulators.max_snow_residual
        max_bare_frozen_residual=checkpoint.accumulators.max_bare_frozen_residual
        max_bare_melting_violation=checkpoint.accumulators.max_bare_melting_violation
        started=time()-checkpoint.elapsed_wall_seconds
        first_step=s.model.clock.iteration+1
        (first_step-1)*dt == s.model.clock.time || error("Restart iteration and time differ")
        first_step <= steps+1 || error("Checkpoint is beyond requested run duration")
        prepare_restart_output!(out,checkpoint.model_hour)
        metrics(s) # Validate the restored moving grid and physical state.
    end
    csv_mode=isempty(restart_path) ? "w" : "a"
    open(joinpath(out,"hourly.csv"),csv_mode) do io
        if isempty(restart_path)
            println(io,"hour,ice_area_m2,ice_volume_m3,snow_volume_m3,max_speed_m_s,max_stress_Pa,Tmin_C,Tmax_C,snow_skin_max_C,snow_residual_W_m2,bare_frozen_residual_W_m2,bare_melting_violation_W_m2,bare_cells,slab_budget_J,ice_mass_budget_kg,snow_mass_budget_kg,accumulated_snowfall_kg,column_height_mismatch_m,ocean_min_C,ocean_max_C,CFL,wall_seconds")
        end
        for n=first_step:steps
            t=s.model.clock.time
            maxstress=max(maxstress,update_wind_stress!(s.u_stress,s.v_stress,s.atmosphere,s.directions,s.wet,t))
            update_snowfall!(s.model.snowfall,s.atmosphere,s.wet,t)
            if n == 1
                actual_stress=max(maximum(abs,interior(s.u_stress)),maximum(abs,interior(s.v_stress)))
                isapprox(actual_stress,maxstress;rtol=1e-12) || error("Wind stress was not written into model fields")
                expected_snow=maximum(interp(s.atmosphere.prsn,i,j,t) for i=1:N,j=1:N if s.wet[i,j])
                actual_snow=maximum(interior(s.model.snowfall))
                isapprox(actual_snow,expected_snow;rtol=1e-12) || error("Snowfall was not written into model field")
            end
            a=Array(interior(s.model.ice_concentration))[:,:,1]
            hs_before=Array(interior(s.model.snow_thickness))[:,:,1]
            Qb=QB_COEFFICIENT .* max.(s.To .- TF,0.0)
            basal_integral+=dt*sum(a .* Qb .* s.area .* s.wet)
            check_hourly = n % max(1,round(Int,3600/dt)) == 0 || n == steps
            surface = time_step_with_surface_state!(s.model,dt,check_hourly)
            s.To .-= dt .* a .* Qb .* s.wet ./ (RHOCP*OCEAN_DEPTH)
            ice_flux=Array(interior(s.model.mass_fluxes.thermodynamics.ice))[:,:,1]
            snow_flux=Array(interior(s.model.mass_fluxes.thermodynamics.snow))[:,:,1]
            snowfall_flux=Array(interior(s.model.mass_fluxes.intercepted_snowfall))[:,:,1]
            diagnose_snow_failure!(s, t, a, hs_before, out)
            ice_mass_flux_integral+=dt*sum(ice_flux .* s.area .* s.wet)
            snow_mass_flux_integral+=dt*sum((snow_flux .+ snowfall_flux) .* s.area .* s.wet)
            snowfall_mass_integral+=dt*sum(snowfall_flux .* s.area .* s.wet)
            if check_hourly
                d=metrics(s)
                slab_residual=RHOCP*OCEAN_DEPTH*sum(s.To .* s.area .* s.wet)-ocean_initial+basal_integral
                ice_budget=900.0*(d.ice_volume-before.ice_volume)-ice_mass_flux_integral
                snow_budget=330.0*(d.snow_volume-before.snow_volume)-snow_mass_flux_integral
                frozen,melting,bare_cells=bare_surface_balance(s,d,dt,surface)
                abs(ice_budget) <= max(100.0,1e-7*abs(ice_mass_flux_integral)) ||
                    error("Ice mass budget failed: $ice_budget kg")
                abs(snow_budget) <= max(10.0,1e-7*abs(snow_mass_flux_integral)) ||
                    error("Snow mass budget failed: $snow_budget kg")
                abs(slab_residual) <= max(1e-9*abs(ocean_initial),1e-7*abs(basal_integral)) ||
                    error("Ocean slab budget failed: $slab_residual J")
                d.snow_residual <= 0.1 || error("Snow surface balance failed: $(d.snow_residual) W/m²")
                frozen <= 0.1 || error("Bare frozen surface balance failed: $frozen W/m²")
                melting <= 0.1 || error("Bare melting surface balance failed: $melting W/m²")
                d.mismatch <= 1e-8 || error("Column geometry mismatch: $(d.mismatch) m")
                max_snow_residual=max(max_snow_residual,d.snow_residual)
                max_bare_frozen_residual=max(max_bare_frozen_residual,frozen)
                max_bare_melting_violation=max(max_bare_melting_violation,melting)
                cfl=horizontal_cfl(s,dt)
                vals=(s.model.clock.time/3600,d.area,d.ice_volume,d.snow_volume,d.speed,maxstress,
                    d.Tmin,d.Tmax,d.snow_skin_max,d.snow_residual,frozen,melting,bare_cells,
                    slab_residual,ice_budget,snow_budget,snowfall_mass_integral,d.mismatch,
                    d.ocean_min,d.ocean_max,cfl,time()-started)
                println(io,join(vals,',')); flush(io)
                if n % round(Int,86400/dt) == 0
                    snapshot(joinpath(out,@sprintf("day_%03d.bin",round(Int,s.model.clock.time/86400))),s,d)
                end
                if n % checkpoint_steps == 0
                    accumulators=(;ocean_initial,basal_integral,ice_mass_flux_integral,
                        snow_mass_flux_integral,snowfall_mass_integral,maxstress,
                        max_snow_residual,max_bare_frozen_residual,max_bare_melting_violation)
                    checkpoint_path=joinpath(out,@sprintf("checkpoint_hour_%05d.bin",round(Int,s.model.clock.time/3600)))
                    save_restart_checkpoint(checkpoint_path,s,dt,before,accumulators,time()-started)
                end
                @info "Forced Arctic column + snow + EVP" hour=vals[1] ice_volume=d.ice_volume snow_volume=d.snow_volume speed=d.speed snow_residual=d.snow_residual wall_seconds=vals[end]
            end
        end
    end
    after=metrics(s)
    snapshot(joinpath(out,"final.bin"),s,after)
    summary=Dict("hours"=>hours,"dt_seconds"=>dt,"steps"=>steps,
        "initial_area_m2"=>before.area,"final_area_m2"=>after.area,
        "initial_ice_volume_m3"=>before.ice_volume,"final_ice_volume_m3"=>after.ice_volume,
        "initial_snow_volume_m3"=>before.snow_volume,"final_snow_volume_m3"=>after.snow_volume,
        "max_velocity_m_s"=>after.speed,"max_air_stress_Pa"=>maxstress,
        "snow_surface_residual_W_m2"=>after.snow_residual,
        "max_snow_surface_residual_W_m2"=>max_snow_residual,
        "max_bare_frozen_residual_W_m2"=>max_bare_frozen_residual,
        "max_bare_melting_violation_W_m2"=>max_bare_melting_violation,
        "ice_mass_budget_residual_kg"=>900.0*(after.ice_volume-before.ice_volume)-ice_mass_flux_integral,
        "snow_mass_budget_residual_kg"=>330.0*(after.snow_volume-before.snow_volume)-snow_mass_flux_integral,
        "integrated_ice_thermodynamic_mass_flux_kg"=>ice_mass_flux_integral,
        "integrated_snow_mass_flux_kg"=>snow_mass_flux_integral,
        "integrated_snowfall_kg"=>snowfall_mass_integral,
        "max_column_height_mismatch_m"=>after.mismatch,
        "minimum_column_temperature_C"=>after.Tmin,"maximum_column_temperature_C"=>after.Tmax,
        "final_CFL"=>horizontal_cfl(s,dt),
        "snow_initialization"=>"min(0.2 m, 0.2*h, 0.8*(rho_w-rho_i)/rho_s*h)",
        "snowfall"=>"prepared JRA55-do prsn, linearly interpolated every model step",
        "wind_stress"=>"rotated geographic JRA55-do winds, quadratic absolute-wind drag",
        "ocean"=>"GLORYS initial temperature, stationary 50 m slab, basal heat exchange",
        "status"=>"completed")
    open(joinpath(out,"summary.toml"),"w") do io
        TOML.print(io,summary;sorted=true)
    end
    println(summary)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
