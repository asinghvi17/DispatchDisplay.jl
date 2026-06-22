# ---------------------------------------------------------------------------
# The data model: a snapshot of "who owns what" over the type grid.
# ---------------------------------------------------------------------------

"""
    DispatchModel

A snapshot of `f`'s dispatch over a concrete type grid.

* `axes`       — ordered candidate types per argument (the grid coordinates).
* `brackets`   — per axis, the abstract-supertype brackets (see [`Bracket`](@ref)).
* `methodlist` — methods that own at least one cell, in stable colour order.
* `grid`       — `Int` array, one entry per cell:
                 `0` uncovered (MethodError), `-1` ambiguous, `-2` partial,
                 `k > 0` owned by `methodlist[k]`.
* `colors`     — one colour per method in `methodlist` (stable per method).
* `provided`   — the user-supplied type space (or `nothing`).
"""
struct DispatchModel
    f::Any
    provided::Union{Nothing,Vector{Vector{Any}}}
    ndims::Int
    axes::Vector{Vector{Any}}
    brackets::Vector{Vector{Bracket}}
    methodlist::Vector{Method}
    colors::Vector{Makie.RGBAf}
    grid::Array{Int}
end

const UNCOVERED = Makie.RGBAf(0.93, 0.93, 0.93, 1.0)   # grid value  0
const AMBIGUOUS = Makie.RGBAf(0.85, 0.20, 0.20, 1.0)   # grid value -1
const PARTIAL   = Makie.RGBAf(0.98, 0.78, 0.30, 1.0)   # grid value -2

"""Distinct, readable colours, steering clear of the reserved grey/red."""
function assign_colors(n::Int)
    n == 0 && return Makie.RGBAf[]
    seed = [Colors.colorant"white", Colors.colorant"black",
            Colors.colorant"gray85", Colors.colorant"red"]
    cols = Colors.distinguishable_colors(n + length(seed), seed; dropseed = true)
    return [Makie.RGBAf(Colors.red(c), Colors.green(c), Colors.blue(c), 1.0) for c in cols[1:n]]
end

# A fixed palette assigned once. A method's colour is its first-seen index into
# this palette, so colours never shuffle when new methods are added later.
const PALETTE = assign_colors(48)
palette_color(i::Integer) = PALETTE[mod1(i, length(PALETTE))]

color_for(model::DispatchModel, v::Integer) =
    v == 0 ? UNCOVERED : v == -1 ? AMBIGUOUS : v == -2 ? PARTIAL : model.colors[v]

"""Give every not-yet-seen method a stable palette index; never reassign one."""
function ensure_order!(order::IdDict{Method,Int}, ms)
    fresh = [m for m in ms if !haskey(order, m)]
    sort!(fresh; by = m -> (string(m.file), m.line, string(m.sig)))
    next = isempty(order) ? 1 : maximum(values(order)) + 1
    for m in fresh
        order[m] = next
        next += 1
    end
    return order
end

"""
A curated palette of common concrete number types — handy for visualising
operators, e.g. `dispatchdisplay(+, numeric_types(), numeric_types())`.
"""
numeric_types() = Any[
    Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt32, UInt64, BigInt,
    Float16, Float32, Float64, BigFloat, Rational{Int}, Complex{Int}, ComplexF64,
]

"""
Axes only ever hold **concrete** types. When `provided`, those are used as given
(`order`ed by the type tree); otherwise the concrete types appearing in `f`'s
signatures are used — abstract types never become cells, they only show up as
method colours and subtype brackets.
"""
function build_axes(f, provided, ndims::Int)
    axes = Vector{Vector{Any}}(undef, ndims)
    if provided !== nothing
        for i in 1:ndims
            axes[i] = order_types(collect(Any, provided[i]))
        end
        return axes
    end
    inferred = infer_axes(f, ndims)
    for i in 1:ndims
        concretes = [T for T in unique(inferred[i]) if T isa Type && isconcretetype(T)]
        isempty(concretes) && error(
            "No concrete argument types found at position $i among `$f`'s " *
            "$ndims-argument methods; pass explicit concrete `types`.")
        axes[i] = order_types(concretes)
    end
    return axes
end

"""
    build_model(f, provided; order) -> DispatchModel

Compute a fresh snapshot. `provided` is `nothing` or a per-argument vector of
candidate types. `order` is a persistent method→palette-index map that keeps
colours stable across refreshes.
"""
function build_model(f, provided::Union{Nothing,Vector{Vector{Any}}};
                     order::IdDict{Method,Int} = IdDict{Method,Int}(),
                     arity::Union{Nothing,Int} = nothing)
    ndims = provided !== nothing ? length(provided) :
            arity !== nothing ? arity : infer_ndims(f)
    1 <= ndims <= 3 ||
        error("DispatchDisplay supports 1–3 arguments; got $ndims.")

    axes = build_axes(f, provided, ndims)
    brackets = [axis_brackets(f, axes[i], i, ndims) for i in 1:ndims]

    allmethods = collect(methods(f))
    ensure_order!(order, allmethods)
    idxof = IdDict{Method,Int}(m => i for (i, m) in enumerate(allmethods))

    dims = Tuple(length(a) for a in axes)
    raw = zeros(Int, dims)
    for I in CartesianIndices(dims)
        owner = cell_owner(f, Tuple(axes[d][I[d]] for d in 1:ndims), allmethods)
        raw[I] = owner === :uncovered ? 0 :
                 owner === :ambiguous ? -1 :
                 owner === :partial   ? -2 :
                 get(idxof, owner, 0)
    end

    # Keep methods that surfaced, ordered by their stable palette index so the
    # legend order (and colours) don't shuffle when methods are added.
    used = unique(filter(>(0), vec(raw)))
    used = used[sortperm([order[allmethods[u]] for u in used])]
    remap = Dict(old => new for (new, old) in enumerate(used))
    grid = map(v -> v > 0 ? remap[v] : v, raw)
    methodlist = allmethods[used]
    colors = [palette_color(order[m]) for m in methodlist]

    return DispatchModel(f, provided, ndims, axes, brackets, methodlist, colors, grid)
end
