# Only a melting-constrained top solves a surface budget.
update_column_surface_fluxes!(top_boundary, thermodynamics, external_flux, clock, model_fields, Δt; snow = nothing, consolidation_thickness = Oceananigans.Fields.ZeroField()) = nothing

function column_surface_energy_solve!(top_boundary, thermodynamics::ColumnEnergyThermodynamics,
                                      external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; snow = nothing)
    grid = thermodynamics.fields.internal_energy.grid
    auxiliary = thermodynamics.auxiliary
    options = thermodynamics.solvers.nonlinear_solver
    E = thermodynamics.fields.internal_energy.data
    E⁰ = copy(E)
    E⁻ = similar(E)
    energy_residual = Inf
    surface_residual = Inf

    for iteration in 1:options.maximum_iterations
        parent(E⁻) .= parent(E)
        compute_column_thermodynamic_diagnostics!(thermodynamics)
        compute_column_transport_coefficients!(thermodynamics)
        update_column_surface_fluxes!(top_boundary, thermodynamics, external_heat_fluxes.top, clock, model_fields, Δt; snow, consolidation_thickness)
        assemble_column_energy_system!(thermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; initial_energy = E⁰)
        solve_column_energy_system!(thermodynamics)

        compute_column_thermodynamic_diagnostics!(thermodynamics)
        compute_column_transport_coefficients!(thermodynamics)
        update_column_surface_fluxes!(top_boundary, thermodynamics, external_heat_fluxes.top, clock, model_fields, Δt; snow, consolidation_thickness)
        assemble_column_energy_system!(thermodynamics, external_heat_fluxes, clock, model_fields, consolidation_thickness, Δt; initial_energy = E⁰)
        launch!(architecture(grid), grid, :xyz, _column_energy_residual!, auxiliary,
                thermodynamics.fields.internal_energy, E⁰, grid, options.relative_tolerance)
        energy_residual = maximum(abs, interior(auxiliary.energy_rhs))
        surface_residual = maximum(abs, interior(auxiliary.surface_fluxes.residual))
        isfinite(energy_residual) && isfinite(surface_residual) || error("Column energy/surface solve produced a nonfinite residual.")
        energy_residual <= 1 && surface_residual <= 1 && return nothing
        parent(E) .= parent(E⁻) .+ options.relaxation .* (parent(E) .- parent(E⁻))
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
