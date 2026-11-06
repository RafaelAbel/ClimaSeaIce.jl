# The bottom flux is cached so that a stateful external flux is evaluated once per step.
@kernel function _cache_column_bottom_external_flux!(Qb, fields, grid, Qe, clock, model_fields)
    i, j = @index(Global, NTuple)
    @inbounds Qb[i, j, 1] = getflux(Qe, i, j, grid, fields.temperature[i, j, 1], clock, model_fields)
end

function cached_external_heat_fluxes(th::ColumnEnergyThermodynamics, Qe, clock, model_fields)
    grid = th.fields.internal_energy.grid
    cache = th.auxiliary.bottom_external_flux
    launch!(architecture(grid), grid, :xy, _cache_column_bottom_external_flux!, cache, th.fields, grid, Qe.bottom, clock, model_fields)
    return (top = Qe.top, bottom = cached_column_bottom_flux(Qe.bottom, cache))
end

@inline cached_column_bottom_flux(bottom, cache) = cache
@inline cached_column_bottom_flux(bottom::ColumnBasalHeatFlux, cache) =
    ColumnBasalHeatFlux(cache, bottom.interface_cell, bottom.frazil)

# Without a snow layer the surface budget sees zero snow thickness, so the placeholder properties never enter it.
column_surface_snow(thermodynamics, ::Nothing) = (thickness = Oceananigans.Fields.ZeroField(), density = 1, conductivity = 1, latent_heat = 1,
                                                  itd_shape = nothing, temperature = thermodynamics.auxiliary.surface_temperature)
column_surface_snow(thermodynamics, snow) = snow

# Only a melting-constrained top solves a surface budget.
update_column_surface_fluxes!(top_boundary, thermodynamics, external_flux, clock, model_fields, Δt; snow = nothing, consolidation_thickness = Oceananigans.Fields.ZeroField()) = nothing

function update_column_surface_fluxes!(::MeltingConstrainedFluxBalance, thermodynamics, external_flux, clock, model_fields, Δt; snow = nothing, consolidation_thickness = Oceananigans.Fields.ZeroField())
    grid = thermodynamics.fields.internal_energy.grid
    launch!(architecture(grid), grid, :xy, _update_column_surface_fluxes!, thermodynamics.auxiliary,
            thermodynamics.fields, grid, external_flux, thermodynamics.relation, thermodynamics.heat_boundary_conditions,
            consolidation_thickness, column_surface_snow(thermodynamics, snow), clock, model_fields, Δt)
    return nothing
end

function column_surface_energy_solve!(top_boundary, thermodynamics::ColumnEnergyThermodynamics,
                                      external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; snow = nothing)
    fields, auxiliary = thermodynamics.fields, thermodynamics.auxiliary
    options = thermodynamics.solvers.nonlinear_solver
    E = fields.internal_energy
    grid = E.grid
    E⁰ = copy(E.data)
    step = similar(E⁰)
    residual = KernelFunctionOperation{Center, Center, Center}(column_energy_residual, grid,
        auxiliary.lower_diagonal, auxiliary.diagonal, auxiliary.upper_diagonal, auxiliary.energy_rhs, E, E⁰, options.relative_tolerance)
    excess_residual = KernelFunctionOperation{Center, Center, Center}(column_energy_excess_residual, grid,
        auxiliary.lower_diagonal, auxiliary.diagonal, auxiliary.upper_diagonal, auxiliary.energy_rhs, E)
    previous_excess = oftype(options.relative_tolerance, Inf)
    step_fraction = one(eltype(grid))
    energy_residual = surface_residual = previous_excess

    compute_column_thermodynamic_diagnostics!(thermodynamics)
    compute_column_transport_coefficients!(thermodynamics)

    # Re-linearize about the current state while holding the start-of-step storage and conductivity fixed.
    for iteration in 0:options.maximum_iterations
        update_column_surface_fluxes!(top_boundary, thermodynamics, external_heat_fluxes.top, clock, model_fields, Δt; snow, consolidation_thickness)
        assemble_column_energy_system!(thermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; initial_energy = E⁰)
        energy_residual = maximum(residual; mask = 0)
        surface_residual = maximum(abs, auxiliary.surface_fluxes.residual)
        isfinite(energy_residual) && isfinite(surface_residual) || error("Column energy/surface solve produced a nonfinite residual.")
        defect = max(energy_residual, surface_residual)
        defect <= 1 && return nothing

        excess = maximum(excess_residual; mask = 0)

        if excess > previous_excess
            # Halve the step that raised the residual. Fractions accumulate: 1 - 1/2 - 1/4 - ...
            step_fraction /= 2
            parent(E) .-= step_fraction .* parent(step)
        else
            previous_excess = excess
            step_fraction = one(eltype(grid))
            parent(step) .= parent(E)
            solve_column_energy_system!(thermodynamics)
            parent(step) .= parent(E) .- parent(step)
        end

        compute_column_thermodynamic_diagnostics!(thermodynamics)
    end

    error("Column energy/surface solve did not converge within $(options.maximum_iterations) iterations (energy residual $energy_residual, normalized surface residual $surface_residual).")
end

function column_energy_time_step!(thermodynamics::ColumnEnergyThermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; snow = nothing)
    fill_halo_regions!((thermodynamics.fields.internal_energy, thermodynamics.fields.bulk_salinity), clock, model_fields)
    column_salinity_time_step!(thermodynamics, Δt)
    compute_column_shortwave_flux!(thermodynamics)
    column_surface_energy_solve!(thermodynamics.heat_boundary_conditions.top, thermodynamics, external_heat_fluxes, clock, model_fields,
                                 consolidation_thickness, Δt; snow)
    return nothing
end

# The column carries its own enthalpy and interface heights, which RK substeps do not reset, so it steps once per full step.
@inline apply_column_thermodynamics_this_stage(timestepper, clock) = true
@inline apply_column_thermodynamics_this_stage(timestepper::SplitRungeKuttaTimeStepper, clock) = clock.stage == timestepper.Nstages
