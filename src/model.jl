# ---------------------------------------------------------------------------
# The data model: a snapshot of "who owns what" over the type grid.
# ---------------------------------------------------------------------------

"""
    DispatchModel

A snapshot of `f`'s dispatch over a typed grid.

* `axes`       — ordered concrete (and rare uncovered-abstract/Union) types per
                 argument; these are the grid coordinates.
* `trees`      — per axis, the DAG over the *tree-node* space, which is a
                 superset of `axes` adding floating abstracts/Unions and
                 intermediate supertypes (see [`AxisTree`](@ref)).
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
    trees::Vector{AxisTree}
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
A curated palette of common concrete matrix types from `Base`, `LinearAlgebra`,
and `SparseArrays` — handy for visualising linear-algebra operators, e.g.
`dispatchdisplay(*, matrix_types(), matrix_types())`. All entries are
`Float64`-valued so they share an element type and dispatch differences come
from matrix *structure* alone.
"""
matrix_types() = Any[
    Matrix{Float64},
    Diagonal{Float64, Vector{Float64}},
    Bidiagonal{Float64, Vector{Float64}},
    Tridiagonal{Float64, Vector{Float64}},
    SymTridiagonal{Float64, Vector{Float64}},
    UpperTriangular{Float64, Matrix{Float64}},
    LowerTriangular{Float64, Matrix{Float64}},
    UnitUpperTriangular{Float64, Matrix{Float64}},
    UnitLowerTriangular{Float64, Matrix{Float64}},
    Symmetric{Float64, Matrix{Float64}},
    Hermitian{Float64, Matrix{Float64}},
    Transpose{Float64, Matrix{Float64}},
    Adjoint{Float64, Matrix{Float64}},
    SparseMatrixCSC{Float64, Int},
]

"""
    build_axis_and_tree_types(f, ndims, i; ...) -> (axis, tree_only, sig_types)

Compose, per axis dimension, the *axis* (grid rows/columns) and the
*tree-only* extras (drawn on the sibling tree axis but with no grid cell):

* `axis` — concrete types literally in signatures, every `Union` constituent
  (always enumerated), plus any abstract/parametric in signatures whose
  coverage no concrete on the axis already provides (an "uncovered" leaf).
* `tree_only` — abstracts/Unions/parametrics in signatures that *are* covered
  by concretes on the axis, plus intermediate supertypes that span ≥2 nodes
  (so the tree is hierarchical rather than a flat `Any → {everything}` fan).
* `sig_types` — every type that literally appeared in a signature at this
  position (so the tree's `has_method` marker is set correctly for floating
  abstract nodes).

`show_*` toggles act as exclusion filters (default everything on).
"""
function build_axis_and_tree_types(f, ndims::Int, i::Int;
                                   show_abstracts::Bool = true,
                                   show_any::Bool = true,
                                   show_unions::Bool = true)
    inferred = infer_axes(f, ndims)[i]
    # Phase 1: collect every candidate type and remember which appeared in
    # a sig (so the tree's has_method bit is right).
    candidates = Set{Any}()
    sig_set = Set{Any}()
    add_candidate! = function(T)
        T isa Type || return
        T === Any && !show_any && return
        _is_type_of_type(T) && return
        if _is_union(T) && !show_unions
            return
        end
        if !isconcretetype(T) && !_is_union(T) && !show_abstracts
            return
        end
        push!(candidates, T)
    end
    for T in unique(inferred)
        push!(sig_set, T)
        add_candidate!(T)
        # Always enumerate Union members — they're concrete (or further union)
        # leaves the method covers, and the user explicitly wants them on axis.
        if _is_union(T)
            for p in expand_union(T)
                add_candidate!(p)
            end
        end
    end
    # Phase 2: split candidates into concrete-on-axis vs. non-concrete.
    concretes = Any[T for T in candidates if isconcretetype(T)]
    nonconcretes = Any[T for T in candidates if !isconcretetype(T)]
    # Phase 3: a non-concrete is tree-only iff some concrete on axis is its
    # subtype. Otherwise it becomes an axis leaf (covers a region the user
    # would otherwise have no cell for).
    axis = copy(concretes)
    tree_only = Any[]
    for T in nonconcretes
        covered = any(C -> _safe_subtype(C, T), concretes)
        push!(covered ? tree_only : axis, T)
    end
    isempty(axis) && error(
        "No axis types found at position $i among `$f`'s " *
        "$ndims-argument methods; pass explicit `types`.")
    # Phase 4: enrich the tree (not the axis) with intermediate supertypes
    # that meaningfully connect ≥2 tree nodes.
    if show_abstracts
        all_tree = vcat(axis, tree_only)
        for extra in enrich_with_ancestors(all_tree)
            extra in all_tree && continue
            extra in tree_only && continue
            push!(tree_only, extra)
        end
    end
    return order_types(axis), order_types(tree_only), sig_set
end

"""
Populate `tree_only` with the abstracts/Unions worth showing as floating tree
nodes for a given `axis`:

* intermediate ancestors of `axis` types that span ≥2 axis entries
  (so the DAG isn't flat), and
* every abstract/Union literally in a signature at this position (so the
  abstract methods' coverage is hinted at in the hierarchy).

Concrete sig types are not added — they only become tree nodes if they're
already on the axis. The caller is responsible for `_is_type_of_type` and
`show_any` filtering on items it adds to `axis`; this helper applies those
same filters to anything it pulls in itself.
"""
function _populate_tree_only!(tree_only::Vector{Any}, axis::AbstractVector,
                              sigs_at_dim;
                              show_abstracts::Bool, show_any::Bool)
    show_abstracts || return tree_only
    for e in enrich_with_ancestors(axis)
        e in axis && continue
        e in tree_only && continue
        push!(tree_only, e)
    end
    for T in sigs_at_dim
        T isa Type || continue
        T === Any && !show_any && continue
        _is_type_of_type(T) && continue
        isconcretetype(T) && continue
        T in axis && continue
        T in tree_only && continue
        push!(tree_only, T)
    end
    return tree_only
end

"""
When `provided`, the supplied types form the axis as-is (every provided entry
gets a grid cell). When inferring, compose axis + tree per
[`build_axis_and_tree_types`](@ref). In both paths the tree is enriched with
ancestors and abstract sig types so the hierarchy is visible.
"""
function build_axes(f, provided, ndims::Int;
                    show_abstracts::Bool = true, show_any::Bool = true,
                    show_unions::Bool = true)
    axes = Vector{Vector{Any}}(undef, ndims)
    tree_only = [Any[] for _ in 1:ndims]
    # `has_method` answers "literally in a signature" — compute from
    # `methods(f)` so it's the same whether the axis was provided or inferred.
    inferred_per_dim = infer_axes(f, ndims)
    sig_sets = [Set{Any}(collect(inferred_per_dim[i])) for i in 1:ndims]
    if provided !== nothing
        for i in 1:ndims
            axes[i] = order_types(collect(Any, provided[i]))
            _populate_tree_only!(tree_only[i], axes[i], inferred_per_dim[i];
                                 show_abstracts = show_abstracts, show_any = show_any)
        end
    else
        for i in 1:ndims
            ax, t_only, _ = build_axis_and_tree_types(f, ndims, i;
                show_abstracts = show_abstracts,
                show_any = show_any,
                show_unions = show_unions)
            axes[i] = ax
            tree_only[i] = t_only
        end
    end
    return (axes, tree_only, sig_sets)
end

"""
    build_model(f, provided; order) -> DispatchModel

Compute a fresh snapshot. `provided` is `nothing` or a per-argument vector of
candidate types. `order` is a persistent method→palette-index map that keeps
colours stable across refreshes.
"""
function build_model(f, provided::Union{Nothing,Vector{Vector{Any}}};
                     order::IdDict{Method,Int} = IdDict{Method,Int}(),
                     arity::Union{Nothing,Int} = nothing,
                     show_abstracts::Bool = true, show_any::Bool = true,
                     show_unions::Bool = true)
    ndims = provided !== nothing ? length(provided) :
            arity !== nothing ? arity : infer_ndims(f)
    1 <= ndims <= 3 ||
        error("DispatchDisplay supports 1–3 arguments; got $ndims.")

    axes, tree_only, sig_sets = build_axes(f, provided, ndims;
                      show_abstracts = show_abstracts, show_any = show_any,
                      show_unions = show_unions)
    trees = Vector{AxisTree}(undef, ndims)
    for i in 1:ndims
        # Tree node order: same chain-key ordering as the axis. Axis entries
        # interleave with floating tree-only nodes in supertype order.
        treevec = order_types(vcat(axes[i], tree_only[i]))
        # `==(::Type)` is finicky for `Union`s (Base.Fix2 has an overly tight
        # signature in some stdlib versions). Use identity comparison instead.
        ax_lookup = let ai = axes[i]
            T -> findfirst(t -> t === T, ai)
        end
        has_method = Bool[any(s -> s === T, sig_sets[i]) for T in treevec]
        trees[i] = build_axis_tree(treevec, has_method, ax_lookup)
    end

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

    return DispatchModel(f, provided, ndims, axes, trees, methodlist, colors, grid)
end
