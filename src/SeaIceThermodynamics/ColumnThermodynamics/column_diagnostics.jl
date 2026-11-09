#####
##### Diagnostics and column energy step
#####

thermal_conductivity(transport::ConductiveTemperatureTransport) = transport.conductivity
energy_diffusivity(transport::ConductiveTemperatureTransport) = transport.diffusivity

salinity_diffusivity(::NoSalinityTransport) = 0
salinity_diffusivity(transport::BulkSalinityDiffusion) = transport.diffusivity

@inline shortwave_flux(::NoShortwaveAbsorption, z, z_top) = zero(z)
@inline shortwave_flux(absorption::ExponentialShortwaveAbsorption, z, z_top) = absorption.surface_transmission * exp((z - z_top) / absorption.attenuation_scale)
