# ---------------------------------------------------------------------------
# Axis layout: tree ordering + DAG over the axis
#
# Each axis is treated as a DAG. Edges encode two relationships at once:
#   * "T is a subtype of U" — supertype-style ancestry.
#   * "T is a Union constituent of U" — Union-membership.
# The DAG's parent set for a node is the *minimal* (most specific) set of
# on-axis types that contain it — so `Int` parented by `Number` (the supertype),
# `Number` parented by `Union{Number,String}` (its containing Union), etc.
# Overlap surfaces naturally as a node with multiple parents (e.g. `Int` lives
# in both a `Number` subtree and a `Union{Int,String}` membership edge).
# ---------------------------------------------------------------------------

function supertype_safe(@nospecialize t)
    # `supertype` is undefined for `Union`s (and `UnionAll`s whose body is a
    # `Union`); for ordering purposes such types simply sit directly under `Any`.
    if t isa UnionAll
        Base.unwrap_unionall(t) isa Union && return Any
    end
    (t isa DataType || t isa UnionAll) ? supertype(t) : Any
end

"""`true` for `Type{X}`/`Type{<:X}` (a type whose instances are themselves types)."""
_is_type_of_type(@nospecialize T) = try
    T <: Type
catch
    true
end

"""`true` when `t` is a `Union` (or a `UnionAll` whose body is a `Union`)."""
function _is_union(@nospecialize t)
    body = t isa UnionAll ? Base.unwrap_unionall(t) : t
    body isa Union
end

"""
    type_chain(T) -> Vector  # [Any, ..., supertype(T), T]

The ancestry of `T` from the root `Any` down to `T` itself.
"""
function type_chain(@nospecialize t)
    chain = Any[t]
    s = t
    while s !== Any
        sup = supertype_safe(s)
        sup === s && break
        push!(chain, sup)
        s = sup
    end
    return reverse(chain)
end

"""Sort key that places types sharing an ancestry prefix next to each other."""
chainkey(@nospecialize t) = String[string(x) for x in type_chain(t)]

"""Deduplicate (by type equality) then order by the supertype tree."""
order_types(types) = sort(unique(types); by = chainkey)

"""
    enrich_with_ancestors(types) -> Vector

Add intermediate abstract supertypes to `types` whenever they would meaningfully
link ≥2 existing entries. Without this, the DAG of e.g. `setindex!`'s axis
collapses to `Any → {Int, Float64, Bool, ...}` because no method literally
writes `::Number`/`::Integer`/`::Real`. Walking each entry's supertype chain
and keeping the ancestors that span ≥2 axis descendants surfaces the numeric
hierarchy without forcing the user to opt in to it.

`Any` is excluded — it's added separately via `show_any`. UnionAll-wrapped
Union ancestors are skipped (their supertype is `Any` anyway).
"""
function enrich_with_ancestors(types)
    seen = Set{Any}(t for t in types if t isa Type)
    candidates = Set{Any}()
    for T in types
        T isa Type || continue
        s = T
        while true
            sup = supertype_safe(s)
            sup === s && break
            sup === Any && break
            sup in seen || push!(candidates, sup)
            s = sup
        end
    end
    extras = Any[]
    for A in candidates
        # Count strict subtypes already on axis (transitive over the original
        # `types` set — ancestors collected above aren't counted as descendants
        # of themselves).
        n = 0
        for T in types
            T isa Type && T !== A && _safe_subtype(T, A) && (n += 1)
            n >= 2 && break
        end
        n >= 2 && push!(extras, A)
    end
    return vcat(collect(types), extras)
end

"""
    AxisTree

DAG over the *tree node* space of one axis dimension. Tree nodes include
every axis entry plus any floating supertype/Union/parametric node that the
user wants visible in the hierarchy (intermediates, abstracts with methods
whose coverage is provided by concrete leaves, etc.).

* `nodes[k]`       — the Julia type at tree-node index `k`.
* `axis_idx[k]`    — `k`'s position in the grid axis, or `nothing` if the
                     node is "floating" (tree-only; no grid row/column).
* `has_method[k]`  — whether the type literally appears in a method
                     signature (vs. being a pure intermediate added so the
                     tree is hierarchical instead of a flat fan).
* `parents[k]`     — minimal set of on-tree types that strictly contain
                     `nodes[k]`. Multiple entries → overlap (DAG edges).
* `children[k]`    — inverse.
* `roots`          — indices with no parents.
* `depth[k]`       — shortest distance to any root.
* `expandable[k]`  — has ≥1 child (collapsing it would hide something).
"""
struct AxisTree
    nodes::Vector{Any}
    axis_idx::Vector{Union{Int,Nothing}}
    has_method::Vector{Bool}
    parents::Vector{Vector{Int}}
    children::Vector{Vector{Int}}
    roots::Vector{Int}
    depth::Vector{Int}
    expandable::Vector{Bool}
end

"""Robust `T <: U` that returns `false` for weird type combinations."""
function _safe_subtype(@nospecialize(T), @nospecialize(U))
    try
        return T <: U
    catch
        return false
    end
end

"""
    build_axis_tree(axisvec, treevec, has_method, axis_lookup) -> AxisTree

`axisvec` is the ordered grid axis (concrete leaves + Union/abstract leaves
that aren't covered by concretes). `treevec` is the *full* ordered tree-node
list (a superset of `axisvec` adding tree-only abstracts/Unions/parametrics
and intermediate supertypes). `has_method[k]` answers "does `treevec[k]`
literally appear in a method signature?". `axis_lookup` maps a tree-node
type back to its axis index when present (else `nothing`).

A parent of `T` in the tree is any on-tree `U` with `T <: U` (`U !== T`),
keeping only the most specific such `U` per DAG branch.
"""
function build_axis_tree(treevec, has_method, axis_lookup)
    n = length(treevec)
    parents = [Int[] for _ in 1:n]

    for k in 1:n
        T = treevec[k]
        T isa Type || continue
        candidates = Int[]
        for j in 1:n
            j == k && continue
            U = treevec[j]
            U isa Type || continue
            _safe_subtype(T, U) && push!(candidates, j)
        end
        for i in candidates
            Ui = treevec[i]
            ismin = true
            for j in candidates
                j == i && continue
                Uj = treevec[j]
                if _safe_subtype(Uj, Ui) && Uj !== Ui
                    ismin = false
                    break
                end
            end
            ismin && push!(parents[k], i)
        end
    end

    children = [Int[] for _ in 1:n]
    for k in 1:n, p in parents[k]
        push!(children[p], k)
    end

    roots = [k for k in 1:n if isempty(parents[k])]

    depth = fill(typemax(Int), n)
    q = Int[]
    for r in roots
        depth[r] = 0
        push!(q, r)
    end
    while !isempty(q)
        k = popfirst!(q)
        for c in children[k]
            d = depth[k] + 1
            if d < depth[c]
                depth[c] = d
                push!(q, c)
            end
        end
    end

    expandable = [!isempty(children[k]) for k in 1:n]
    axis_idx = [axis_lookup(treevec[k]) for k in 1:n]
    return AxisTree(collect(treevec), axis_idx, collect(Bool, has_method),
                    parents, children, roots, depth, expandable)
end

"""Greatest depth in the tree (0 if there are no edges)."""
tree_depth(t::AxisTree) =
    isempty(t.children) ? 0 : maximum(d for d in t.depth if d < typemax(Int); init = 0)
