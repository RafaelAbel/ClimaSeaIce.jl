using Oceananigans: prognostic_state, prognostic_fields, restore_prognostic_state!
using KernelAbstractions: @kernel, @index
using Oceananigans.Architectures: architecture
using Oceananigans.Fields: set!
using Oceananigans.Grids: ZDirection, rnode
using Oceananigans.Solvers: BatchedTridiagonalSolver
using Oceananigans.Utils: launch!

# Enthalpy/temperature/salinity relations and the moving two-interface vertical coordinate.
include("column_energy_relations.jl")
include("sea_ice_column_discretization.jl")

# Closures and the `ColumnEnergyThermodynamics` type, its fields, constructors, and presets.
include("column_parameterizations.jl")
include("column_energy_thermodynamics.jl")

# Thermodynamic diagnostics.
include("column_diagnostics.jl")
