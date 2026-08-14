using DelimitedFiles
using Oceananigans
using Oceananigans.Units
using Oceananigans.Fields: interior
using Oceananigans.Grids: Center, φnode
using Oceananigans.Operators: Azᶜᶜᵃ
using Oceananigans.OutputReaders: FieldTimeSeries, OnDisk

"""Load each output part and return time-sorted, de-duplicated entries."""
function collect_entries(paths)
    entries = NamedTuple[]
    for path in paths
        # A file split exactly at the output interval can contain a single
        # snapshot. OnDisk supports that whereas InMemory requires ≥2 slots.
        fts = FieldTimeSeries(path, "siconc"; backend = OnDisk())
        for index in eachindex(fts.times)
            push!(entries, (; time = Float64(fts.times[index] / days), series = fts, index))
        end
    end

    sort!(entries; by = entry -> entry.time)
    seen = Set{Float64}()
    unique_entries = NamedTuple[]
    for entry in entries
        time = round(entry.time; digits = 8)
        time in seen && continue
        push!(seen, time)
        push!(unique_entries, entry)
    end
    return unique_entries
end

"""Northern Hemisphere sea-ice extent in million km² for a 15% SIC threshold."""
function arctic_extent_million_km2(entry)
    concentration = Array(interior(entry.series[entry.index]))
    grid = entry.series.grid
    Nx, Ny, _ = size(grid)
    total_area = 0.0

    for j in 1:Ny, i in 1:Nx
        φnode(i, j, 1, grid, Center(), Center(), Center()) > 0 || continue
        concentration_ij = concentration[i, j, 1]
        isfinite(concentration_ij) && concentration_ij >= 0.15 || continue
        total_area += Azᶜᶜᵃ(i, j, 1, grid)
    end

    return total_area / 1e12
end

function main()
    length(ARGS) ≥ 2 || error("usage: julia export_arctic_sie.jl OUT.csv SURFACE_PART [SURFACE_PART ...]")
    output_path, surface_paths... = ARGS
    entries = collect_entries(surface_paths)

    open(output_path, "w") do io
        println(io, "day,arctic_extent_million_km2")
        for entry in entries
            println(io, "$(entry.time),$(arctic_extent_million_km2(entry))")
        end
    end
    println("wrote $output_path")
end

main()
