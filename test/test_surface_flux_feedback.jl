using Test
include("../validation/surface_flux_feedback.jl")
include("../validation/nonlinear_surface_feedback.jl")

@testset "Nonlinear atmospheric heat flux" begin
    # Saturated air at the surface temperature and balanced longwave give zero flux.
    for T in (-60.0, -35.0, -10.0, 0.0)
        air = merge(SYNTHETIC_AIR, (; temperature=T, relative_humidity=1.0,
                    downward_longwave=5.670374419e-8 * (T + 273.15)^4))
        @test atmospheric_heat_flux(T, air) ≈ 0 atol=1e-12
        @test atmospheric_heat_flux(T + 1, air) > 0
        @test atmospheric_heat_flux(T - 1, air) < 0
    end
end

@testset "Nonlinear surface feedback and column heat budget" begin
    lagged = nonlinear_surface_feedback(:lagged)[2:end]
    @test maximum(abs.(diff(getproperty.(lagged, :Ts)))) > 50
    @test maximum(abs(r.budget_residual) for r in lagged) > 1000
    # A prescribed field conserves its supplied flux, even when that flux is stale.
    @test maximum(abs(r.exchanged_budget_residual) for r in lagged) < 1e-5

    # Each case covers one hour. Check weak, strong, and radiative-only exchange.
    for Δt in (600.0, 300.0, 60.0), H in (0.0, 5.0, 25.0)
        air = merge(SYNTHETIC_AIR, (; sensible_coefficient=H, mass_coefficient=H / 1005))
        rows = nonlinear_surface_feedback(:live; Δt, steps=Int(3600 / Δt), air)[2:end]
        @test all(-35 < r.Ts < -1 for r in rows)
        @test maximum(abs.(diff(getproperty.(rows, :Ts)))) < 1
        @test maximum(abs(r.surface_residual) for r in rows) < 1e-6
        @test maximum(abs(r.budget_residual) for r in rows) < 1e-5
    end
end

@testset "Surface feedback through a complete ice step" begin
    lagged = surface_flux_feedback(:lagged; verbose=false)
    @test maximum(abs.(diff(lagged[2:end]))) > 40

    for Δt in (600.0, 300.0, 60.0)
        steps = Int(3600 / Δt)
        live = surface_flux_feedback(:live; Δt, steps, verbose=false)
        @test all(isfinite, live)
        @test all(-48 .< live[2:end] .< -10)
        @test maximum(abs.(diff(live[2:end]))) < 5
    end
end
