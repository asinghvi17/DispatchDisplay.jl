# ---------------------------------------------------------------------------
# Axis layout: tree ordering + abstract-supertype brackets
#
# Axes only ever show the concrete candidate types. Subtyping is conveyed by
# *brackets*: for every abstract type that appears in a method signature we draw
# a bracket spanning the axis types that are its subtypes, and nest brackets by
# containment (e.g. `Integer` inside `Real` inside `Number`).
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

"""A subtyping bracket spanning axis indices `lo:hi`, nested at `depth`."""
struct Bracket
    label::String
    lo::Int
    hi::Int
    depth::Int
end

"""
    axis_brackets(f, axisvec, dim, ndims) -> Vector{Bracket}

For argument position `dim`, find every abstract type appearing in `f`'s method
signatures and bracket the axis types (`axisvec`) that are its subtypes. Nesting
`depth` counts how many other brackets strictly contain each one.
"""
function axis_brackets(f, axisvec, dim::Int, ndims::Int)
    abstracts = Any[]
    for m in methods(f)
        isvararg(m) && continue
        ats = arg_types(m)
        length(ats) == ndims || continue
        for T in expand_union(ats[dim])
            # Skip `Any`, concrete types, and the `Type{<:X}` supertypes that
            # appear when a function dispatches on `Type{...}` (those would make
            # a noisy all-spanning bracket, e.g. rock-paper-scissors).
            (T === Any || !(T isa Type) || isconcretetype(T) || _is_type_of_type(T)) &&
                continue
            push!(abstracts, T)
        end
    end

    spans = Tuple{Any,Int,Int}[]
    for T in unique(abstracts)
        # A bracket needs at least one *strict* subtype on the axis — otherwise
        # the bracket just hugs T's own axis tick, which is redundant. When T is
        # itself on the axis, include its index in the span so the bracket
        # visibly originates at the abstract-type cell.
        strict = [i for (i, U) in enumerate(axisvec) if U isa Type && U !== T && U <: T]
        isempty(strict) && continue
        own = findfirst(U -> U === T, axisvec)
        idxs = own === nothing ? strict : vcat(strict, own)
        push!(spans, (T, minimum(idxs), maximum(idxs)))
    end

    # Depth = how many other brackets this one *encloses*, so broader supertypes
    # sit further out and the most specific bracket hugs the axis.
    brackets = Bracket[]
    for (T, lo, hi) in spans
        depth = 0
        for (U, lo2, hi2) in spans
            U === T && continue
            encloses = lo <= lo2 && hi2 <= hi
            narrower = (hi2 - lo2) < (hi - lo)
            samespan = lo2 == lo && hi2 == hi
            if encloses && (narrower || (samespan && U isa Type && U <: T))
                depth += 1
            end
        end
        push!(brackets, Bracket(string(T), lo, hi, depth))
    end
    return brackets
end
