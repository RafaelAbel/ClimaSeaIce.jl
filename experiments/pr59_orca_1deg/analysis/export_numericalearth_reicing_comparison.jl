using DelimitedFiles
using Oceananigans
using Oceananigans.Units
using Oceananigans.Fields: interior
using Oceananigans.Grids: Center, λnode, φnode
using Oceananigans.Operators: Azᶜᶜᵃ
using Oceananigans.OutputReaders: FieldTimeSeries, InMemory

normalize_longitude(λ) = mod(λ + 180, 360) - 180

function mask_from_bounds(grid; lon_bounds, lat_bounds)
    Nx, Ny, _ = size(grid)
    mask = falses(Nx, Ny)
    lon_min, lon_max = lon_bounds
    lat_min, lat_max = lat_bounds

    for j in 1:Ny, i in 1:Nx
        λ = normalize_longitude(λnode(i, j, 1, grid, Center(), Center(), Center()))
        φ = φnode(i, j, 1, grid, Center(), Center(), Center())
        mask[i, j] = lon_min <= λ <= lon_max && lat_min <= φ <= lat_max
    end

    any(mask) || error("Empty mask for lon=$(lon_bounds), lat=$(lat_bounds)")
    return mask
end

function open_parts(paths::Vector{String}, variable::String)
    return [FieldTimeSeries(path, variable; backend = InMemory(2)) for path in paths]
end

function collect_series_entries(parts)
    entries = NamedTuple[]
    for part in parts
        for index in eachindex(part.times)
            push!(entries, (; time = Float64(part.times[index] / days), series = part, index))
        end
    end
    sort!(entries; by = entry -> entry.time)
    deduped = NamedTuple[]
    seen = Set{Float64}()
    for entry in entries
        rounded = round(entry.time; digits = 8)
        rounded in seen && continue
        push!(seen, rounded)
        push!(deduped, entry)
    end
    return deduped
end

function arctic_extent_million_km2(concentration_fts, index)
    concentration = Array(interior(concentration_fts[index]))
    grid = concentration_fts.grid
    Nx, Ny, _ = size(grid)
    total_area = 0.0
    for j in 1:Ny, i in 1:Nx
        φ = φnode(i, j, 1, grid, Center(), Center(), Center())
        φ > 0 || continue
        c = concentration[i, j, 1]
        isfinite(c) || continue
        c >= 0.15 || continue
        total_area += Azᶜᶜᵃ(i, j, 1, grid)
    end
    return total_area / 1e12
end

function write_extent_csv(path, baseline_entries, baseline_conc, reicing_entries, reicing_conc)
    common_times = intersect(
        Set(round(entry.time; digits = 8) for entry in baseline_entries),
        Set(round(entry.time; digits = 8) for entry in reicing_entries),
    )
    common_times = sort!(collect(common_times))
    isempty(common_times) && error("No overlapping times between baseline and re-icing runs")

    baseline_lookup = Dict(round(entry.time; digits = 8) => entry for entry in baseline_entries)
    reicing_lookup = Dict(round(entry.time; digits = 8) => entry for entry in reicing_entries)

    open(path, "w") do io
        println(io, "day,baseline_arctic_extent_million_km2,reicing_arctic_extent_million_km2,delta_million_km2")
        for day in common_times
            baseline_entry = baseline_lookup[day]
            reicing_entry = reicing_lookup[day]
            baseline_extent = arctic_extent_million_km2(baseline_entry.series, baseline_entry.index)
            reicing_extent = arctic_extent_million_km2(reicing_entry.series, reicing_entry.index)
            println(
                io,
                join(
                    [
                        string(day),
                        string(baseline_extent),
                        string(reicing_extent),
                        string(reicing_extent - baseline_extent),
                    ],
                    ",",
                ),
            )
        end
    end

    return common_times
end

function extract_beaufort_snapshot(path_prefix, target_entry_h, target_entry_c; lon_bounds, lat_bounds)
    thickness = Array(interior(target_entry_h.series[target_entry_h.index]))
    concentration = Array(interior(target_entry_c.series[target_entry_c.index]))
    grid = target_entry_h.series.grid
    Nx, Ny, _ = size(grid)
    mask = mask_from_bounds(grid; lon_bounds, lat_bounds)

    I = findall(any(mask, dims = 2)[:, 1])
    J = findall(any(mask, dims = 1)[1, :])
    i1, i2 = first(I), last(I)
    j1, j2 = first(J), last(J)

    ni = i2 - i1 + 1
    nj = j2 - j1 + 1
    lon = fill(NaN, ni, nj)
    lat = fill(NaN, ni, nj)
    thick = fill(NaN, ni, nj)
    conc = fill(NaN, ni, nj)

    for (ii, i) in enumerate(i1:i2), (jj, j) in enumerate(j1:j2)
        λ = normalize_longitude(λnode(i, j, 1, grid, Center(), Center(), Center()))
        φ = φnode(i, j, 1, grid, Center(), Center(), Center())
        lon[ii, jj] = λ
        lat[ii, jj] = φ
        if mask[i, j]
            thick[ii, jj] = thickness[i, j, 1]
            conc[ii, jj] = concentration[i, j, 1]
        end
    end

    writedlm(path_prefix * "_lon.csv", lon, ',')
    writedlm(path_prefix * "_lat.csv", lat, ',')
    writedlm(path_prefix * "_thickness.csv", thick, ',')
    writedlm(path_prefix * "_concentration.csv", conc, ',')

    return lon, lat, thick, conc
end

function write_metadata(path; target_day, lon_bounds, lat_bounds)
    open(path, "w") do io
        println(io, "target_day=$target_day")
        println(io, "lon_min=$(lon_bounds[1])")
        println(io, "lon_max=$(lon_bounds[2])")
        println(io, "lat_min=$(lat_bounds[1])")
        println(io, "lat_max=$(lat_bounds[2])")
    end
end

function main()
    length(ARGS) == 5 || error(
        "usage: julia export_numericalearth_reicing_comparison.jl BASELINE_PART1 BASELINE_PART2 REICING_PART1 REICING_PART2 OUTDIR"
    )

    baseline_paths = ARGS[1:2]
    reicing_paths = ARGS[3:4]
    outdir = ARGS[5]
    mkpath(outdir)

    baseline_h = open_parts(baseline_paths, "sithick")
    baseline_c = open_parts(baseline_paths, "siconc")
    reicing_h = open_parts(reicing_paths, "sithick")
    reicing_c = open_parts(reicing_paths, "siconc")

    baseline_entries_h = collect_series_entries(baseline_h)
    baseline_entries_c = collect_series_entries(baseline_c)
    reicing_entries_h = collect_series_entries(reicing_h)
    reicing_entries_c = collect_series_entries(reicing_c)

    common_times = write_extent_csv(
        joinpath(outdir, "arctic_extent_timeseries.csv"),
        baseline_entries_c,
        baseline_c,
        reicing_entries_c,
        reicing_c,
    )

    target_day = maximum(common_times)
    baseline_h_lookup = Dict(round(entry.time; digits = 8) => entry for entry in baseline_entries_h)
    baseline_c_lookup = Dict(round(entry.time; digits = 8) => entry for entry in baseline_entries_c)
    reicing_h_lookup = Dict(round(entry.time; digits = 8) => entry for entry in reicing_entries_h)
    reicing_c_lookup = Dict(round(entry.time; digits = 8) => entry for entry in reicing_entries_c)

    baseline_h_entry = baseline_h_lookup[target_day]
    baseline_c_entry = baseline_c_lookup[target_day]
    reicing_h_entry = reicing_h_lookup[target_day]
    reicing_c_entry = reicing_c_lookup[target_day]

    lon_bounds = (-155.0, -125.0)
    lat_bounds = (69.0, 79.0)

    _, _, baseline_thick, _ = extract_beaufort_snapshot(
        joinpath(outdir, "baseline_beaufort"),
        baseline_h_entry,
        baseline_c_entry;
        lon_bounds,
        lat_bounds,
    )

    _, _, reicing_thick, _ = extract_beaufort_snapshot(
        joinpath(outdir, "reicing_beaufort"),
        reicing_h_entry,
        reicing_c_entry;
        lon_bounds,
        lat_bounds,
    )

    difference = reicing_thick .- baseline_thick
    writedlm(joinpath(outdir, "beaufort_difference.csv"), difference, ',')

    # Keep the original plot script input names.
    cp(joinpath(outdir, "reicing_beaufort_lon.csv"), joinpath(outdir, "beaufort_lon.csv"); force = true)
    cp(joinpath(outdir, "reicing_beaufort_lat.csv"), joinpath(outdir, "beaufort_lat.csv"); force = true)
    cp(joinpath(outdir, "reicing_beaufort_thickness.csv"), joinpath(outdir, "beaufort_thickness.csv"); force = true)

    write_metadata(joinpath(outdir, "beaufort_metadata.txt"); target_day, lon_bounds, lat_bounds)
    println("wrote $(outdir)")
end

main()
