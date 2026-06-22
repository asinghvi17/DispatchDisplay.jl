# ---------------------------------------------------------------------------
# Method / type introspection
#
# Everything in here is plain reflection over `methods(f)` and `which`.
# The key insight driving the whole package: a single concrete cell of the
# grid asks "if I called `f` with exactly these argument types, which method
# would Julia dispatch to?".  `which` answers that; `methods(f, T)` and a
# try/catch let us tell *uncovered* (MethodError) apart from *ambiguous*.
# ---------------------------------------------------------------------------

"""Resolve a signature element to a usable type (TypeVars collapse to their bound)."""
resolve_type(@nospecialize t) = t isa TypeVar ? resolve_type(t.ub) : t

"""`true` if the method has a trailing `Vararg` slot (we can't grid those)."""
function isvararg(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    ps = sig.parameters
    return !isempty(ps) && Base.isvarargtype(ps[end])
end

"""Argument signature types of a method, excluding the leading function-object slot."""
function arg_types(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    ats = sig.parameters[2:end]
    return Any[resolve_type(a) for a in ats]
end

"""Number of declared positional arguments (function slot excluded)."""
arity(m::Method) = length(arg_types(m))

"""Split a `Union` into its component types; everything else passes through."""
expand_union(@nospecialize t) = t isa Union ? collect(Base.uniontypes(t)) : Any[t]

"""
    infer_ndims(f) -> Int

Pick the dimensionality of the grid from the (non-vararg) methods of `f`,
choosing the most common arity when methods disagree.
"""
function infer_ndims(f)
    counts = Dict{Int,Int}()
    for m in methods(f)
        isvararg(m) && continue
        n = arity(m)
        counts[n] = get(counts, n, 0) + 1
    end
    isempty(counts) && error("`$f` has no fixed-arity methods to display.")
    best = argmax(counts)
    if length(counts) > 1
        @warn "`$f` has methods of differing arity $(sort(collect(keys(counts)))); displaying $best-argument methods. Pass `types` to choose explicitly."
    end
    return best
end

"""
    infer_axes(f, ndims) -> Vector{Vector{Any}}

Collect, per argument position, every type literally mentioned in the
signatures of `f`'s `ndims`-argument methods (Unions expanded).
"""
function infer_axes(f, ndims::Int)
    axes = [Any[] for _ in 1:ndims]
    for m in methods(f)
        isvararg(m) && continue
        ats = arg_types(m)
        length(ats) == ndims || continue
        for i in 1:ndims, t in expand_union(ats[i])
            push!(axes[i], t)
        end
    end
    return axes
end

"""
    method_source(m) -> String | nothing

The textual source of a method's definition (via CodeTracking), or `nothing`
when the defining file can't be read.
"""
function method_source(m::Method)
    r = try
        CodeTracking.definition(String, m)
    catch
        nothing
    end
    r === nothing ? nothing : first(r)
end

"""
    cell_owner(f, types) -> Method | :uncovered | :partial | :ambiguous

Which method owns the cell described by the tuple of `types`:

* `:uncovered`  — no method's signature intersects (a real `MethodError`).
* `:partial`    — some method intersects but none covers the whole cell. This
                  only happens for *abstract* cells (e.g. `(Number, String)`):
                  certain concrete subtypes dispatch somewhere, the rest don't.
* `:ambiguous`  — several equally-specific methods cover it, none most specific.
* a `Method`    — the single method Julia would dispatch to.
"""
function cell_owner(f, types, ms = methods(f))
    argT = Tuple{types...}
    fullT = Tuple{typeof(f),types...}
    # Fast path for all-concrete cells (the common case, and the only kind on
    # our axes): a concrete query is either covered by exactly one method, truly
    # ambiguous, or uncovered — never "partial". `which` + `hasmethod` settle it
    # without the O(#methods) intersection scan, which matters for big grids.
    if all(T -> T isa Type && isconcretetype(T), types)
        hasmethod(f, argT) && return which(f, argT)   # covered: no thrown exception
        for m in ms                                   # not covered: ambiguous vs none
            typeintersect(fullT, m.sig) === Union{} || return :ambiguous
        end
        return :uncovered
    end
    # General path (abstract query types): a method *intersects* the cell if
    # their signatures share concrete types, and *covers* it if the whole cell
    # signature is a subtype of the method's.
    intersects = false
    covered = false
    for m in ms
        typeintersect(fullT, m.sig) === Union{} && continue
        intersects = true
        fullT <: m.sig && (covered = true)
    end
    intersects || return :uncovered
    covered || return :partial
    try
        return which(f, argT)
    catch
        return :ambiguous
    end
end
