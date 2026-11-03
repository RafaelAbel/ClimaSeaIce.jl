#####
##### Boundary contributions to the column energy solve. External heat fluxes are upward-positive: a direct flux enters
##### the top cell as -Qᵘ and the bottom cell as +Qᵇ. Dirichlet boundaries add an implicit conductance and a conductive flux.
#####

@inline function flux_temperature_derivative(i, j, grid, T, flux, clock, model_fields)
    δT = sqrt(eps(eltype(grid))) * max(one(T), abs(T))
    return (getflux(flux, i, j, grid, T + δT, clock, model_fields) - getflux(flux, i, j, grid, T, clock, model_fields)) / δT
end

@inline function column_bottom_boundary_energy_factor(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    T = @inbounds fields.temperature[i, j, k]
    D = flux_temperature_derivative(i, j, grid, T, ext, clock, model_fields)
    return -Δt * D * fields.temperature_energy_derivative[i, j, k] / Δzᶜᶜᶜ(i, j, k, grid)
end

@inline function column_top_boundary_energy_factor(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    T = @inbounds fields.temperature[i, j, k]
    D = flux_temperature_derivative(i, j, grid, T, ext, clock, model_fields)
    return Δt * D * fields.temperature_energy_derivative[i, j, k] / Δzᶜᶜᶜ(i, j, k, grid)
end

@inline function column_bottom_boundary_energy_factor(bc::ColumnDirichletBoundary, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    conductance = column_boundary_temperature_conductance(i, j, 1, k, grid, auxiliary)
    TE = @inbounds fields.temperature_energy_derivative[i, j, k]
    return Δt * conductance * TE / Δzᶜᶜᶜ(i, j, k, grid)
end

@inline function column_top_boundary_energy_factor(bc::ColumnDirichletBoundary, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    Nz = size(grid, 3)
    conductance = column_boundary_temperature_conductance(i, j, Nz+1, k, grid, auxiliary)
    TE = @inbounds fields.temperature_energy_derivative[i, j, k]
    return Δt * conductance * TE / Δzᶜᶜᶜ(i, j, k, grid)
end

@inline function column_top_boundary_energy_factor(bc::MeltingConstrainedFluxBalance, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    Tₛ = @inbounds auxiliary.surface_temperature[i, j, 1]
    Tₘ = melting_temperature(relation.phase_transitions.liquidus, @inbounds fields.bulk_salinity[i, j, k])
    C = column_boundary_temperature_conductance(i, j, k+1, k, grid, auxiliary)
    D = flux_temperature_derivative(i, j, grid, Tₛ, ext, clock, model_fields)
    conductance = ifelse((Tₛ < Tₘ) & (C > 0), D / (1 + D / C), zero(D))
    TE = @inbounds fields.temperature_energy_derivative[i, j, k]
    return Δt * conductance * TE / Δzᶜᶜᶜ(i, j, k, grid)
end

@inline function column_bottom_boundary_energy_flux(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    T = @inbounds fields.temperature[i, j, k]
    D = flux_temperature_derivative(i, j, grid, T, ext, clock, model_fields)
    return - getflux(ext, i, j, grid, T, clock, model_fields) + D * fields.temperature_energy_derivative[i, j, k] * fields.internal_energy[i, j, k]
end

@inline function column_top_boundary_energy_flux(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    T = @inbounds fields.temperature[i, j, k]
    D = flux_temperature_derivative(i, j, grid, T, ext, clock, model_fields)
    return - getflux(ext, i, j, grid, T, clock, model_fields) + D * fields.temperature_energy_derivative[i, j, k] * fields.internal_energy[i, j, k]
end

# A Dirichlet base couples to the interior by conduction only; its external flux enters the basal Stefan balance.
@inline function column_bottom_boundary_energy_flux(bc::ColumnDirichletBoundary, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    conductance = column_boundary_temperature_conductance(i, j, 1, k, grid, auxiliary)
    T  = @inbounds fields.temperature[i, j, k]
    E  = @inbounds fields.internal_energy[i, j, k]
    TE = @inbounds fields.temperature_energy_derivative[i, j, k]
    Tᵇ = column_dirichlet_temperature(bc, i, j, grid, relation)
    return conductance * (T - Tᵇ - TE * E)
end

@inline function column_top_boundary_energy_flux(bc::ColumnDirichletBoundary, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    Nz = size(grid, 3)
    conductance = column_boundary_temperature_conductance(i, j, Nz+1, k, grid, auxiliary)
    T  = @inbounds fields.temperature[i, j, k]
    E  = @inbounds fields.internal_energy[i, j, k]
    TE = @inbounds fields.temperature_energy_derivative[i, j, k]
    Tᵇ = column_dirichlet_temperature(bc, i, j, grid, relation)
    return conductance * (Tᵇ - T + TE * E) - getflux(ext, i, j, grid, Tᵇ, clock, model_fields)
end

# The surface flux -Qᵘ(Tₛ) is capped at the energy that completely melts the top cell; the excess drives surface melt.
@inline function column_top_boundary_energy_flux(bc::MeltingConstrainedFluxBalance, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    Δz = Δzᶜᶜᶜ(i, j, k, grid)
    E  = @inbounds fields.internal_energy[i, j, k]
    S  = @inbounds fields.bulk_salinity[i, j, k]
    Tₛ = @inbounds auxiliary.surface_temperature[i, j, 1]
    requested = - getflux(ext, i, j, grid, Tₛ, clock, model_fields)
    E⁰ = @inbounds auxiliary.surface_start_energy[i, j, 1]
    available = column_energy_to_complete_melt(relation, E⁰, S, Δz) / Δt
    factor = column_top_boundary_energy_factor(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    return min(requested, max(available, zero(available))) + factor * Δz / Δt * E
end

@inline column_surface_stefan_residual_flux(bc, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt) = zero(eltype(grid))

@inline function column_surface_stefan_residual_flux(bc::MeltingConstrainedFluxBalance, ext, i, j, k, grid, auxiliary, fields, relation, clock, model_fields, Δt)
    Δz = Δzᶜᶜᶜ(i, j, k, grid)
    # the cap is evaluated against the start-of-step enthalpy, the same one the surface solve used
    E  = @inbounds auxiliary.surface_start_energy[i, j, 1]
    S  = @inbounds fields.bulk_salinity[i, j, k]
    Tₛ = @inbounds auxiliary.surface_temperature[i, j, 1]
    requested = - getflux(ext, i, j, grid, Tₛ, clock, model_fields)
    available = column_energy_to_complete_melt(relation, E, S, Δz) / Δt
    applied = min(requested, max(available, zero(available)))
    return applied - requested
end

