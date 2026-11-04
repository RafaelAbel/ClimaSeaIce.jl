# The bottom flux is cached so that a stateful external flux is evaluated once per step.
@kernel function _cache_column_bottom_external_flux!(Qb, fields, grid, Qe, clock, model_fields)
    i, j = @index(Global, NTuple)
    @inbounds Qb[i, j, 1] = getflux(Qe, i, j, grid, fields.temperature[i, j, 1], clock, model_fields)
end

function cached_external_heat_fluxes(th::ColumnEnergyThermodynamics, Qe, clock, model_fields)
    grid = th.fields.internal_energy.grid
    cache = th.auxiliary.bottom_external_flux
    launch!(architecture(grid), grid, :xy, _cache_column_bottom_external_flux!, cache, th.fields, grid, Qe.bottom, clock, model_fields)
    return (top = Qe.top, bottom = cache)
end

function column_surface_energy_solve!(top_boundary, thermodynamics::ColumnEnergyThermodynamics,
                                      external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; max_iterations = 128)
    fields, auxiliary = thermodynamics.fields, thermodynamics.auxiliary
    E = fields.internal_energy
    grid, arch = E.grid, architecture(E.grid)
    tolerance = sqrt(eps(eltype(grid)))
    energy = interior(E)
    Nz = size(grid, 3)

    E⁰ = copy(energy)
    interior(auxiliary.surface_start_energy) .= view(E⁰, :, :, Nz:Nz)
    residual = KernelFunctionOperation{Center, Center, Center}(column_energy_residual, grid,
        auxiliary.lower_diagonal, auxiliary.diagonal, auxiliary.upper_diagonal, auxiliary.energy_rhs, E)
    step = similar(E⁰)
    previous_defect = oftype(tolerance, Inf)
    residual_scale = zero(tolerance)
    step_fraction = one(eltype(grid))

    # Re-linearize the conductive flux while holding the start-of-step storage fixed.
    for iteration in 0:max_iterations
        compute_column_thermodynamic_diagnostics!(thermodynamics)
        iteration == 0 && compute_column_transport_coefficients!(thermodynamics)
        if top_boundary isa MeltingConstrainedFluxBalance
            launch!(arch, grid, :xy, _update_column_surface_temperature!, auxiliary, fields, grid,
                    external_heat_fluxes.top, thermodynamics.relation, clock, model_fields)
        end
        assemble_column_energy_system!(thermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; initial_energy = E⁰)
        defect = maximum(residual; mask = 0)
        iteration == 0 && (residual_scale = min(defect, maximum(abs, E; mask = 0)))
        defect <= tolerance * max(one(tolerance), residual_scale) && return nothing
        if defect > previous_defect
            step_fraction /= 2
            energy .-= step_fraction .* step
        else
            previous_defect = defect
            step_fraction = one(eltype(grid))
            iteration == max_iterations && break
            step .= energy
            solve_column_energy_system!(thermodynamics)
            step .= energy .- step
        end
    end
    error("Column energy solve did not converge within $max_iterations iterations.")
end

function column_energy_time_step!(thermodynamics::ColumnEnergyThermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt)
    compute_column_shortwave_flux!(thermodynamics)
    column_surface_energy_solve!(thermodynamics.heat_boundary_conditions.top, thermodynamics, external_heat_fluxes, clock, model_fields,
                                 consolidation_thickness, Δt)
    column_salinity_time_step!(thermodynamics, Δt)
    return nothing
end

# The column carries its own enthalpy and interface heights, which RK substeps do not reset, so it steps once per full step.
@inline apply_column_thermodynamics_this_stage(timestepper, clock) = true
@inline apply_column_thermodynamics_this_stage(timestepper::SplitRungeKuttaTimeStepper, clock) = clock.stage == timestepper.Nstages

function thermodynamic_time_step!(model, th::ColumnEnergyThermodynamics, ::Nothing, Δt)
    apply_column_thermodynamics_this_stage(model.timestepper, model.clock) || return nothing
    Qe = cached_external_heat_fluxes(th, model.external_heat_fluxes, model.clock, fields(model))
    column_energy_time_step!(th, Qe, model.clock, fields(model), model.ice_consolidation_thickness, Δt)
    column_stefan_volume_update!(th, model, Qe, Δt)
    return nothing
end
