#####
##### Diagnostics and column energy step
#####

thermal_conductivity(transport::ConductiveTemperatureTransport) = transport.conductivity
energy_diffusivity(transport::ConductiveTemperatureTransport) = transport.diffusivity

salinity_diffusivity(::NoSalinityTransport) = 0
salinity_diffusivity(transport::BulkSalinityDiffusion) = transport.diffusivity

@inline shortwave_flux(::NoShortwaveAbsorption, z, z_top) = zero(z)
@inline shortwave_flux(absorption::ExponentialShortwaveAbsorption, z, z_top) = absorption.surface_transmission * exp((z - z_top) / absorption.attenuation_scale)

@kernel function _compute_column_internal_energy!(Φ, ℝ)
    i, j, k = @index(Global, NTuple)
    @inbounds Φ.internal_energy[i, j, k] = internal_energy(ℝ, Φ.temperature[i, j, k], Φ.bulk_salinity[i, j, k])
end

"""
    compute_column_internal_energy!(thermodynamics)

Fill the internal-energy field from the current temperature and bulk-salinity fields.
"""
function compute_column_internal_energy!(thermodynamics::ColumnEnergyThermodynamics)
    grid = thermodynamics.fields.internal_energy.grid
    launch!(architecture(grid), grid, :xyz, _compute_column_internal_energy!, thermodynamics.fields, thermodynamics.relation)
    return nothing
end

@kernel function _compute_column_thermodynamic_diagnostics!(Φ, ℝ)
    i, j, k = @index(Global, NTuple)

    @inbounds begin
        E = Φ.internal_energy[i, j, k]
        S = Φ.bulk_salinity[i, j, k]

        Φ.temperature[i, j, k] = temperature(ℝ, E, S)
        Φ.liquid_fraction[i, j, k] = liquid_fraction(ℝ, E, S)
        Φ.brine_salinity[i, j, k] = brine_salinity(ℝ, E, S)
        Φ.temperature_energy_derivative[i, j, k] = temperature_energy_derivative(ℝ, E, S)
        Φ.temperature_salinity_derivative[i, j, k] = temperature_salinity_derivative(ℝ, E, S)
    end
end

"""
    compute_column_thermodynamic_diagnostics!(thermodynamics)

Fill temperature, liquid fraction, brine salinity, and the thermodynamic derivatives from internal energy and bulk salinity.
"""
function compute_column_thermodynamic_diagnostics!(thermodynamics::ColumnEnergyThermodynamics)
    grid = thermodynamics.fields.internal_energy.grid
    launch!(architecture(grid), grid, :xyz, _compute_column_thermodynamic_diagnostics!, thermodynamics.fields, thermodynamics.relation)
    return nothing
end
