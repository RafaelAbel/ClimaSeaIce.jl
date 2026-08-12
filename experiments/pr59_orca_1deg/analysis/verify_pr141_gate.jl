using Oceananigans
using Oceananigans.Fields: interior
using Oceananigans.OutputReaders: FieldTimeSeries, InMemory

"""Return the earliest and latest records for `name` across output parts."""
function first_and_last_records(paths, name)
    records = NamedTuple[]

    for path in paths
        series = FieldTimeSeries(path, name; backend = InMemory(2))
        for index in eachindex(series.times)
            push!(records, (; time = Float64(series.times[index]), series, index))
        end
    end

    isempty(records) && error("No records found for $name")
    sort!(records; by = record -> record.time)
    return first(records), last(records)
end

function evolution_summary(paths, name)
    first_record, last_record = first_and_last_records(paths, name)
    initial = Array(interior(first_record.series[first_record.index]))
    final = Array(interior(last_record.series[last_record.index]))

    finite = isfinite.(initial) .& isfinite.(final)
    difference = abs.(final .- initial)
    tolerance = sqrt(eps(eltype(difference)))
    changed = finite .& (difference .> tolerance)

    return (; name,
            initial_time_days = first_record.time / Oceananigans.Units.days,
            final_time_days = last_record.time / Oceananigans.Units.days,
            finite_cells = count(finite),
            changed_cells = count(changed),
            max_abs_change = maximum(difference[finite]),
            initial_minimum = minimum(initial[finite]),
            initial_maximum = maximum(initial[finite]),
            final_minimum = minimum(final[finite]),
            final_maximum = maximum(final[finite]))
end

function main()
    length(ARGS) ≥ 1 || error("usage: julia verify_pr141_gate.jl SURFACE_PART [SURFACE_PART ...]")
    summaries = [evolution_summary(ARGS, name) for name in ("sithick", "siconc")]

    for summary in summaries
        println("$(summary.name): t=$(summary.initial_time_days) → $(summary.final_time_days) days; " *
                "changed=$(summary.changed_cells)/$(summary.finite_cells); " *
                "max |Δ|=$(summary.max_abs_change); " *
                "range $(summary.initial_minimum):$(summary.initial_maximum) → " *
                "$(summary.final_minimum):$(summary.final_maximum)")
        summary.changed_cells > 0 || error("$(summary.name) is unchanged across the available output times")
    end
end

main()
