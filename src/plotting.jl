# ---------------------------------------------------------------------------
# Rendering: 1D strip / 2D heatmap / 3D sliced cubes, a custom legend whose
# entry highlights when you hover the matching cell, and (only when method
# sources are too long to inline) a hover panel showing the method's source.
#
# Cells are drawn with exact RGBA colours (`image!(interpolate=false)` in 1D/2D;
# `meshscatter` cubes in 3D). Hovering a cell drives `hovered` (legend row to
# highlight) and `info` (the hover-panel text, used only in non-inline mode).
# ---------------------------------------------------------------------------

const HINT = "Hover a cell to see which method it dispatches to."
const INLINE_MAXLEN = 66   # max source length to show inline in the legend
const ABSTRACT_ALPHA = 0.5 # fill alpha for cells whose axis type is abstract

"""`true` when `T` is an abstract axis entry (so its cell should be faded)."""
is_abstract_axis(@nospecialize T) =
    T isa Type && !isconcretetype(T)

"""Fade a fill colour to mark a cell whose axis type is abstract."""
fade(c::Makie.RGBAf) = Makie.RGBAf(c.r, c.g, c.b, c.alpha * ABSTRACT_ALPHA)

"""Drop module qualifiers and truncate, keeping labels short (full name on hover)."""
function _shorten(s::AbstractString; maxlen::Int = 22)
    s = replace(s, r"[A-Za-z_][A-Za-z0-9_]*\." => "")   # Foo.Bar.Baz -> Baz
    length(s) > maxlen && (s = string(first(s, maxlen - 1), "…"))
    return s
end

"""Short axis label for a candidate type; `Type{Rock}` displays as just `Rock`."""
function typelabel(@nospecialize T)
    base = (T isa DataType && T <: Type && length(T.parameters) == 1 &&
            !(T.parameters[1] isa TypeVar)) ? string(T.parameters[1]) : string(T)
    return _shorten(base)
end

"""Best-effort display name for a function (closures keep their gensym name)."""
funcname(@nospecialize f) = try
    string(nameof(f))
catch
    string(f)
end

"""`f(::T1, ::T2)` with shortened type names, optionally with `(file:line)`."""
function method_label(m::Method, fname::AbstractString; loc::Bool = true)
    args = join(("::" * _shorten(string(a); maxlen = 30) for a in arg_types(m)), ", ")
    sig = string(fname, "(", args, ")")
    loc || return sig
    return string(sig, "  (", basename(string(m.file)), ":", m.line, ")")
end

"""Signature string for a cell query like `f(::Int, ::String)`."""
cell_sig(model, types) =
    string(funcname(model.f), "(", join(("::" * string(T) for T in types), ", "), ")")

"""Multi-line description of a cell, shown in the hover panel (non-inline mode)."""
function describe_cell(model::DispatchModel, v::Integer, types)
    sig = cell_sig(model, types)
    note = any(is_abstract_axis, types) ?
           "\n(faded: at least one axis type is abstract.)" : ""
    if v > 0
        m = model.methodlist[v]
        src = method_source(m)
        body = src === nothing ? method_label(m, funcname(model.f)) : src
        return string("● ", sig, "  →  dispatches to:\n", body,
            "\n@ ", basename(string(m.file)), ":", m.line, note)
    elseif v == 0
        return string("✖ ", sig, "\nMethodError — no applicable method (uncovered).", note)
    elseif v == -2
        return string("◐ ", sig,
            "\nPartial — some concrete subtypes dispatch, others don't.", note)
    else
        return string("⚠ ", sig,
            "\nAmbiguous — several equally-specific methods, none most specific.", note)
    end
end

# --- legend rows ------------------------------------------------------------

"""One-line source for a method, or `nothing` if it isn't short enough to inline."""
function inline_source(m::Method)
    s = method_source(m)
    s === nothing && return nothing
    s = strip(s)
    (occursin('\n', s) || length(s) > INLINE_MAXLEN) ? nothing : s
end

"""
    legend_rows(model) -> (rows, v2r, inline)

Legend rows `(colour, label)`, a map from grid value to legend row, and whether
we're in *inline* mode. When every method's source is short, labels are the
source itself (and no separate hover panel is needed); otherwise labels are
signatures and the hover panel carries the source.
"""
function legend_rows(model::DispatchModel)
    fname = funcname(model.f)
    sources = [inline_source(m) for m in model.methodlist]
    inline = !isempty(sources) && all(!isnothing, sources)

    rows = Tuple{Makie.RGBAf,String}[]
    v2r = Dict{Int,Int}()
    for (i, m) in enumerate(model.methodlist)
        label = inline ? sources[i]::AbstractString : method_label(m, fname; loc = false)
        push!(rows, (model.colors[i], String(label)))
        v2r[i] = length(rows)
    end
    if any(==(0), model.grid)
        push!(rows, (UNCOVERED, "uncovered (MethodError)")); v2r[0] = length(rows)
    end
    if any(==(-2), model.grid)
        push!(rows, (PARTIAL, "partial (some subtypes covered)")); v2r[-2] = length(rows)
    end
    if any(==(-1), model.grid)
        push!(rows, (AMBIGUOUS, "ambiguous")); v2r[-1] = length(rows)
    end
    if any(is_abstract_axis, Iterators.flatten(model.axes))
        push!(rows, (Makie.RGBAf(0.45, 0.45, 0.45, ABSTRACT_ALPHA),
                     "faded fill — abstract-type axis"))
    end
    return rows, v2r, inline
end

# --- bracket trees on linked sibling axes ------------------------------------
#
# Each grid axis-dimension gets a sibling Axis sharing its data coordinate
# with the main grid (`linkxaxes!`/`linkyaxes!`). Subtyping renders as nested
# span brackets; union membership as one dashed rail per Union sig type,
# dotted at the member columns in the owning method's colour. (A node-link
# tree crosses edges at multi-parent DAG nodes and needs one edge per union
# member.) Bands stack grid-outward: leaf labels, rails, then brackets with
# the most specific level nearest the grid.

const TREE_LINE        = Makie.RGBAf(0.45, 0.45, 0.45, 1.0)
const TREE_LABEL_DARK  = Makie.RGBAf(0.12, 0.12, 0.12, 1.0)   # concrete + has method
const TREE_LABEL_MID   = Makie.RGBAf(0.32, 0.32, 0.32, 1.0)   # abstract/Union + has method
const TREE_LABEL_LIGHT = Makie.RGBAf(0.55, 0.55, 0.55, 1.0)   # no own method (pure intermediate)
const TREE_LANE_PX  = 24.0     # union-rail lane pitch (px)
const TREE_LEVEL_PX = 30.0     # bracket level pitch (px)
const TREE_LEAF_FS    = 12.0
const TREE_BRACKET_FS = 11.0
const TREE_RAIL_FS    = 10.5

# Em-normalised per-character advances; one cache serves every font size.
const _ADVANCE_CACHE = Dict{Char,Float64}()

"""Pixel width of `s` at `fontsize` from glyph advances (char-count fallback)."""
function text_width_px(s::AbstractString, fontsize::Real)
    w = 0.0
    for c in s
        w += get!(_ADVANCE_CACHE, c) do
            try
                font = Makie.to_font("TeX Gyre Heros Makie")
                Float64(Makie.FreeTypeAbstraction.hadvance(
                    Makie.FreeTypeAbstraction.get_extent(font, c)))
            catch
                0.6
            end
        end
    end
    return w * fontsize
end

_is_leafnode(t::AxisTree, k::Int) = t.axis_idx[k] !== nothing
_is_unionnode(t::AxisTree, k::Int) = t.nodes[k] isa Type && _is_union(t.nodes[k])

"""
    _leaf_span(tree, k; include_self = true) -> Vector{Int}

Sorted axis positions under tree node `k`: its on-axis leaf descendants, plus
its own column when it is itself on the axis. Rails pass `include_self=false`
— a union's rail marks its members, not its own cell.
"""
function _leaf_span(t::AxisTree, k::Int; include_self::Bool = true)
    seen = Set{Int}()
    q = Int[k]
    while !isempty(q)
        j = popfirst!(q)
        for c in t.children[j]
            c in seen && continue
            push!(seen, c)
            push!(q, c)
        end
    end
    include_self && push!(seen, k)
    return sort!(Int[t.axis_idx[j] for j in seen if t.axis_idx[j] !== nothing])
end

"""Colour of the unique method whose signature literally contains `T`;
grey when zero or several do."""
function _union_method_color(model::DispatchModel, @nospecialize(T))
    found = 0
    col = TREE_LINE
    for (i, m) in enumerate(model.methodlist)
        any(a -> a === T, arg_types(m)) || continue
        found += 1
        col = model.colors[i]
    end
    return found == 1 ? col : TREE_LINE
end

"""Label colour tier — concrete-with-method darkest, intermediate lightest."""
_tree_label_color(@nospecialize(T), has_method::Bool) =
    has_method ? (isconcretetype(T) ? TREE_LABEL_DARK : TREE_LABEL_MID) :
                 TREE_LABEL_LIGHT

"""Italic for abstracts and Unions."""
_tree_label_font(@nospecialize(T)) = isconcretetype(T) ? :regular : :italic

"""Leaf label; a Union leaf reads `A ∪ B` rather than `Union{A, …`."""
_leaf_label(@nospecialize(T)) = _is_union(T) ?
    join((typelabel(p) for p in expand_union(T)), " ∪ ") : typelabel(T)

"""Largest rail label fitting `span_px`: `A ∪ B ∪ C`, else `A ∪ ⋯ ∪ Z`,
else `∪ n types`."""
function _rail_label(member_labels::Vector{String}, span_px::Real)
    fits(s) = text_width_px(s, TREE_RAIL_FS) <= 0.9 * span_px
    full = join(member_labels, " ∪ ")
    fits(full) && return full
    if length(member_labels) > 1
        mid = string(member_labels[1], " ∪ ⋯ ∪ ", member_labels[end])
        fits(mid) && return mid
    end
    return "∪ $(length(member_labels)) types"
end

"""Interior grid boundaries between depth-1 sibling subtrees."""
function _block_seps(t::AxisTree, n::Int)
    seps = Float64[]
    for k in 1:length(t.nodes)
        t.depth[k] == 1 || continue
        _is_unionnode(t, k) && continue
        isempty(t.children[k]) && continue
        lp = _leaf_span(t, k)
        isempty(lp) && continue
        for b in (first(lp) - 0.5, last(lp) + 0.5)
            0.5 < b < n + 0.5 || continue
            any(x -> isapprox(x, b), seps) || push!(seps, b)
        end
    end
    return sort!(seps)
end

"""
    tree_bands(model, dim, cellpx; top) -> (; t, lanes, brackets, bdepths, leafpx, rot, total)

Band geometry for one axis dimension, in px. `lanes`: union nodes with
on-axis members, narrowest span first. `brackets`: non-union nodes with
children; `bdepths` maps bracket depth → level (most specific = level 0,
nearest the grid — safe as a level key under single inheritance). Top axes
rotate leaf labels 45° (`rot`) when the widest label exceeds `cellpx`.
`total` is the band height (top) or width (left).
"""
function tree_bands(model::DispatchModel, dim::Int, cellpx::Real; top::Bool)
    t = model.trees[dim]
    lanes = [k for k in 1:length(t.nodes)
             if _is_unionnode(t, k) && !isempty(_leaf_span(t, k; include_self = false))]
    sort!(lanes; by = k -> (s = _leaf_span(t, k; include_self = false);
                            last(s) - first(s)))
    brackets = [k for k in 1:length(t.nodes)
                if !_is_unionnode(t, k) && !isempty(t.children[k]) &&
                   !isempty(_leaf_span(t, k))]
    bdepths = sort!(unique(t.depth[k] for k in brackets); rev = true)
    maxleaf = maximum((text_width_px(_shorten(_leaf_label(t.nodes[k]); maxlen = 30),
                                     TREE_LEAF_FS)
                       for k in 1:length(t.nodes) if _is_leafnode(t, k)); init = 30.0)
    rot = top && maxleaf > 0.88 * cellpx
    leafpx = top ? (rot ? 0.74 * maxleaf + 12.0 : 20.0) : maxleaf + 14.0
    total = leafpx + TREE_LANE_PX * length(lanes) + (isempty(lanes) ? 0.0 : 4.0) +
            TREE_LEVEL_PX * length(bdepths) + 8.0
    return (; t, lanes, brackets, bdepths, leafpx, rot, total)
end

"""
    tree_axis_top!(pos, model, main; cellpx, dim = 1) -> Makie.Axis

Sibling x-tree `Axis` above `main`: leaf labels against the grid, union
rails, then nested brackets. `cellpx` (on-screen column width) drives label
fitting.
"""
function tree_axis_top!(pos, model::DispatchModel, main::Makie.Axis;
                        cellpx::Real, dim::Int = 1)
    b = tree_bands(model, dim, cellpx; top = true)
    t = b.t
    ax = Makie.Axis(pos;
        xticks = (Float64[], String[]), xticklabelsvisible = false,
        xticksvisible = false, xgridvisible = false,
        yticks = (Float64[], String[]), yticklabelsvisible = false,
        yticksvisible = false, ygridvisible = false)
    Makie.hidespines!(ax)
    Makie.linkxaxes!(main, ax)
    # leaf labels
    for k in 1:length(t.nodes)
        _is_leafnode(t, k) || continue
        T = t.nodes[k]
        T isa Type || continue
        lbl = _shorten(_leaf_label(T); maxlen = 30)
        color = _tree_label_color(T, t.has_method[k])
        font = _tree_label_font(T)
        if b.rot
            Makie.text!(ax, t.axis_idx[k] - 0.08, 3.0;
                text = lbl, align = (:left, :bottom),
                rotation = Float32(pi / 4), fontsize = TREE_LEAF_FS - 1,
                color = color, font = font)
        else
            Makie.text!(ax, Float64(t.axis_idx[k]), 3.0;
                text = lbl, align = (:center, :bottom),
                fontsize = TREE_LEAF_FS, color = color, font = font)
        end
    end
    # union rails
    for (lane, k) in enumerate(b.lanes)
        T = t.nodes[k]
        lp = _leaf_span(t, k; include_self = false)
        col = _union_method_color(model, T)
        y = b.leafpx + (lane - 1) * TREE_LANE_PX + 8.0
        Makie.lines!(ax, [Makie.Point2f(first(lp) - 0.3, y),
                          Makie.Point2f(last(lp) + 0.3, y)];
            color = col, linewidth = 1.6, linestyle = :dash)
        Makie.scatter!(ax, Float64.(lp), fill(y, length(lp));
            color = col, markersize = 7)
        members = String[typelabel(model.axes[dim][i]) for i in lp]
        Makie.text!(ax, (first(lp) + last(lp)) / 2, y + 3.0;
            text = _rail_label(members, (last(lp) - first(lp) + 0.6) * cellpx),
            align = (:center, :bottom), fontsize = TREE_RAIL_FS,
            color = col, font = :italic)
    end
    # nested brackets
    y0 = b.leafpx + TREE_LANE_PX * length(b.lanes) + (isempty(b.lanes) ? 0.0 : 4.0)
    for k in b.brackets
        T = t.nodes[k]
        lvl = findfirst(==(t.depth[k]), b.bdepths) - 1
        lp = _leaf_span(t, k)
        lo = first(lp) - 0.40 - 0.05 * lvl      # outer levels reach slightly wider
        hi = last(lp) + 0.40 + 0.05 * lvl
        y = y0 + lvl * TREE_LEVEL_PX + 12.0
        lbl = _shorten(typelabel(T); maxlen = 24)
        gapw = (text_width_px(lbl, TREE_BRACKET_FS) + 12.0) / cellpx
        xm = (lo + hi) / 2
        color = _tree_label_color(T, t.has_method[k])
        segs = Makie.Point2f[]
        push!(segs, Makie.Point2f(lo, y), Makie.Point2f(lo, y - 6))  # end ticks toward grid
        push!(segs, Makie.Point2f(hi, y), Makie.Point2f(hi, y - 6))
        if gapw < 0.8 * (hi - lo)
            # label set into a gap in the bracket line
            push!(segs, Makie.Point2f(lo, y), Makie.Point2f(xm - gapw / 2, y))
            push!(segs, Makie.Point2f(xm + gapw / 2, y), Makie.Point2f(hi, y))
            Makie.text!(ax, xm, y; text = lbl, align = (:center, :center),
                fontsize = TREE_BRACKET_FS, color = color, font = _tree_label_font(T))
        else
            # too narrow for an in-line label
            push!(segs, Makie.Point2f(lo, y), Makie.Point2f(hi, y))
            Makie.text!(ax, xm, y + 3.0; text = lbl, align = (:center, :bottom),
                fontsize = TREE_BRACKET_FS, color = color, font = _tree_label_font(T))
        end
        Makie.linesegments!(ax, segs; color = TREE_LINE, linewidth = 1.3)
    end
    Makie.ylims!(ax, 0.0, b.total)
    return ax
end

"""
    tree_axis_left!(pos, model, main; cellpx, dim = 2) -> Makie.Axis

Mirror of [`tree_axis_top!`](@ref) left of `main`: negative x (root
leftmost), rail and bracket labels rotated 90°. `cellpx` is the on-screen
row height.
"""
function tree_axis_left!(pos, model::DispatchModel, main::Makie.Axis;
                         cellpx::Real, dim::Int = 2)
    b = tree_bands(model, dim, cellpx; top = false)
    t = b.t
    ax = Makie.Axis(pos;
        xticks = (Float64[], String[]), xticklabelsvisible = false,
        xticksvisible = false, xgridvisible = false,
        yticks = (Float64[], String[]), yticklabelsvisible = false,
        yticksvisible = false, ygridvisible = false)
    Makie.hidespines!(ax)
    Makie.linkyaxes!(main, ax)
    Makie.xlims!(ax, -b.total, 0.0)
    for k in 1:length(t.nodes)
        _is_leafnode(t, k) || continue
        T = t.nodes[k]
        T isa Type || continue
        Makie.text!(ax, -6.0, Float64(t.axis_idx[k]);
            text = _shorten(_leaf_label(T); maxlen = 30),
            align = (:right, :center), fontsize = TREE_LEAF_FS,
            color = _tree_label_color(T, t.has_method[k]),
            font = _tree_label_font(T))
    end
    for (lane, k) in enumerate(b.lanes)
        T = t.nodes[k]
        lp = _leaf_span(t, k; include_self = false)
        col = _union_method_color(model, T)
        x = -(b.leafpx + (lane - 1) * TREE_LANE_PX + 8.0)
        Makie.lines!(ax, [Makie.Point2f(x, first(lp) - 0.3),
                          Makie.Point2f(x, last(lp) + 0.3)];
            color = col, linewidth = 1.6, linestyle = :dash)
        Makie.scatter!(ax, fill(x, length(lp)), Float64.(lp);
            color = col, markersize = 7)
        members = String[typelabel(model.axes[dim][i]) for i in lp]
        Makie.text!(ax, x - 3.0, (first(lp) + last(lp)) / 2;
            text = _rail_label(members, (last(lp) - first(lp) + 0.6) * cellpx),
            align = (:center, :bottom), rotation = Float32(pi / 2),
            fontsize = TREE_RAIL_FS, color = col, font = :italic)
    end
    x0 = b.leafpx + TREE_LANE_PX * length(b.lanes) + (isempty(b.lanes) ? 0.0 : 4.0)
    for k in b.brackets
        T = t.nodes[k]
        lvl = findfirst(==(t.depth[k]), b.bdepths) - 1
        lp = _leaf_span(t, k)
        lo = first(lp) - 0.40 - 0.05 * lvl
        hi = last(lp) + 0.40 + 0.05 * lvl
        x = -(x0 + lvl * TREE_LEVEL_PX + 12.0)
        lbl = _shorten(typelabel(T); maxlen = 24)
        gapw = (text_width_px(lbl, TREE_BRACKET_FS) + 12.0) / cellpx
        ym = (lo + hi) / 2
        color = _tree_label_color(T, t.has_method[k])
        segs = Makie.Point2f[]
        push!(segs, Makie.Point2f(x, lo), Makie.Point2f(x + 6, lo))  # end ticks toward grid
        push!(segs, Makie.Point2f(x, hi), Makie.Point2f(x + 6, hi))
        if gapw < 0.8 * (hi - lo)
            push!(segs, Makie.Point2f(x, lo), Makie.Point2f(x, ym - gapw / 2))
            push!(segs, Makie.Point2f(x, ym + gapw / 2), Makie.Point2f(x, hi))
            Makie.text!(ax, x, ym; text = lbl, align = (:center, :center),
                rotation = Float32(pi / 2), fontsize = TREE_BRACKET_FS,
                color = color, font = _tree_label_font(T))
        else
            push!(segs, Makie.Point2f(x, lo), Makie.Point2f(x, hi))
            Makie.text!(ax, x - 3.0, ym; text = lbl, align = (:center, :bottom),
                rotation = Float32(pi / 2), fontsize = TREE_BRACKET_FS,
                color = color, font = _tree_label_font(T))
        end
        Makie.linesegments!(ax, segs; color = TREE_LINE, linewidth = 1.3)
    end
    return ax
end

"""Default 1D figure height: the `_render!` stack (title + tree + strip +
panel + legend + toggles) at the default 660px width."""
function default_1d_height(model::DispatchModel)
    n = length(model.axes[1])
    cell = clamp((660.0 - 40.0) / n, 16.0, 96.0)
    tree = any(model.trees[1].expandable) ?
           tree_bands(model, 1, cell; top = true).total : 0.0
    rows, _, inline = legend_rows(model)
    nmeth = length(model.methodlist)
    panel = (nmeth > 0 && (nmeth > 16 || !inline)) ? 96.0 : 0.0
    legend = (isempty(rows) || nmeth > 16) ? 0.0 :
             legend_layout(length(rows))[2] * 24.0 + 30.0
    return 24.0 + tree + cell + panel + legend + 44.0 + 10.0 * 5 + 28.0
end

const MAXLABELS = 30   # hide tick labels above this many visible cells (zoom to reveal)

"""Tick (positions, labels) for axis entries visible in `[lo, hi]`; empty when
more than `MAXLABELS` are visible, so a big grid reads as a clean field until you
zoom in (GLMakie scroll-zoom). Re-runs on every zoom/pan via [`lod_ticks!`](@ref)."""
function _visible_ticks(lo, hi, names)
    n = length(names)
    imin = max(1, ceil(Int, lo))
    imax = min(n, floor(Int, hi))
    (imin > imax || imax - imin + 1 > MAXLABELS) && return (Float64[], String[])
    return (collect(Float64, imin:imax), names[imin:imax])
end

"""Drive an axis's tick labels from its visible limits (level-of-detail zoom)."""
function lod_ticks!(ax, n1, n2 = nothing)
    Makie.on(ax.finallimits; update = true) do lims
        o = lims.origin
        w = lims.widths
        ax.xticks = _visible_ticks(o[1], o[1] + w[1], n1)
        n2 === nothing || (ax.yticks = _visible_ticks(o[2], o[2] + w[2], n2))
    end
end

"""
    _highlight_outline(grid, h, nx, ny) -> Vector{Point2f}

Outer-boundary edge segments for cells in `grid` whose value equals `h` —
only edges that face a non-matching neighbour are drawn, so the union of
matching cells gets a single outline (any number of disjoint components,
each with its own outer ring). Returns an empty vector when `h <= 0`
(no method to highlight).
"""
function _highlight_outline(grid, h::Integer, nx::Int, ny::Int)
    segs = Makie.Point2f[]
    h <= 0 && return segs
    matches(i, j) = 1 <= i <= nx && 1 <= j <= ny &&
                    (ndims(grid) == 1 ? grid[i] == h : grid[i, j] == h)
    for i in 1:nx, j in 1:ny
        matches(i, j) || continue
        # top edge — bordering (i, j+1)
        matches(i, j + 1) ||
            push!(segs, Makie.Point2f(i - 0.5, j + 0.5),
                         Makie.Point2f(i + 0.5, j + 0.5))
        # bottom edge — bordering (i, j-1)
        matches(i, j - 1) ||
            push!(segs, Makie.Point2f(i - 0.5, j - 0.5),
                         Makie.Point2f(i + 0.5, j - 0.5))
        # left edge — bordering (i-1, j)
        matches(i - 1, j) ||
            push!(segs, Makie.Point2f(i - 0.5, j - 0.5),
                         Makie.Point2f(i - 0.5, j + 0.5))
        # right edge — bordering (i+1, j)
        matches(i + 1, j) ||
            push!(segs, Makie.Point2f(i + 0.5, j - 0.5),
                         Makie.Point2f(i + 0.5, j + 0.5))
    end
    return segs
end

"""Heavier separators at depth-1 subtree boundaries, echoing the axis
brackets inside the grid."""
function block_separators!(ax, model::DispatchModel, nx::Int, ny::Int)
    segs = Makie.Point2f[]
    for b in _block_seps(model.trees[1], nx)
        push!(segs, Makie.Point2f(b, 0.5), Makie.Point2f(b, ny + 0.5))
    end
    if model.ndims >= 2
        for b in _block_seps(model.trees[2], ny)
            push!(segs, Makie.Point2f(0.5, b), Makie.Point2f(nx + 0.5, b))
        end
    end
    isempty(segs) ||
        Makie.linesegments!(ax, segs; color = (:white, 0.95), linewidth = 3.5)
end

"""Thin cell separators, confined to the grid (not spanning into the margins)."""
function cell_borders!(ax, nx, ny)
    segs = Makie.Point2f[]
    for i in 1:(nx - 1)
        push!(segs, Makie.Point2f(i + 0.5, 0.5), Makie.Point2f(i + 0.5, ny + 0.5))
    end
    for j in 1:(ny - 1)
        push!(segs, Makie.Point2f(0.5, j + 0.5), Makie.Point2f(nx + 0.5, j + 0.5))
    end
    isempty(segs) || Makie.linesegments!(ax, segs; color = (:white, 0.85), linewidth = 1.5)
end

# --- per-dimension plots ----------------------------------------------------

function plot_1d!(pos, model, hovered, info, infocolor;
                  show_title::Bool = true, show_axis_labels::Bool = false)
    n = length(model.axes[1])
    names = typelabel.(model.axes[1])
    # Tick labels live on the tree axis above by default; when trees are
    # toggled off, fall back to standard axis tick labels here.
    ax = Makie.Axis(pos;
        title = show_title ? "$(funcname(model.f))(arg₁)" : "",
        xticks = show_axis_labels ? (1:n, names) : (1:n, fill("", n)),
        xticklabelsvisible = show_axis_labels,
        xticksvisible = show_axis_labels,
        xticklabelrotation = pi / 4,
        xgridvisible = false,
        yticks = (Float64[], String[]), yticklabelsvisible = false,
        yticksvisible = false, ygridvisible = false,
        aspect = Makie.DataAspect())
    Makie.hidespines!(ax)
    abs1 = is_abstract_axis.(model.axes[1])
    cols = Matrix{Makie.RGBAf}(undef, n, 1)
    for i in 1:n
        c = color_for(model, model.grid[i])
        cols[i, 1] = abs1[i] ? fade(c) : c
    end
    Makie.image!(ax, (0.5, n + 0.5), (0.5, 1.5), cols; interpolate = false)
    cell_borders!(ax, n, 1)
    block_separators!(ax, model, n, 1)
    # Highlight: outer boundary of cells matching `hovered` (only the edges
    # that border a non-matching cell are drawn, giving a single outline
    # around the whole region rather than per-cell boxes).
    hl_segs_1d = Makie.lift(hovered) do h
        _highlight_outline(model.grid, h, n, 1)
    end
    Makie.linesegments!(ax, hl_segs_1d; color = (:white, 0.95), linewidth = 4)
    Makie.linesegments!(ax, hl_segs_1d; color = :black, linewidth = 1.5)
    Makie.limits!(ax, 0.5, n + 0.5, 0.5, 1.5)
    Makie.on(Makie.events(ax.scene).mouseposition) do _
        if Makie.is_mouseinside(ax.scene)
            p = Makie.mouseposition(ax.scene)
            i = round(Int, p[1])
            if 1 <= i <= n && 0.5 <= p[2] <= 1.5
                v = model.grid[i]
                hovered[] = v
                info[] = describe_cell(model, v, (model.axes[1][i],))
                infocolor[] = color_for(model, v)
                return
            end
        end
        hovered[] = 0; info[] = HINT; infocolor[] = Makie.RGBAf(0, 0, 0, 0)
    end
    return ax
end

function plot_2d!(pos, model, hovered, info, infocolor;
                  show_title::Bool = true, show_axis_labels::Bool = false)
    nx, ny = length(model.axes[1]), length(model.axes[2])
    big = nx * ny > 600
    namesX = typelabel.(model.axes[1])
    namesY = typelabel.(model.axes[2])
    # Tree leaves own the tick labels by default; the trees-off toggle falls
    # back to standard axis tick labels here. `valign=:top, halign=:left`
    # anchor the DataAspect-shrunken axis to the tree-adjacent corner;
    # `alignmode=Outside(0)` strips the default tick/title protrusion margin.
    ax = Makie.Axis(pos;
        title = show_title ? "$(funcname(model.f))(arg₁, arg₂)" : "",
        xticks = show_axis_labels ? (1:nx, namesX) : (Float64[], String[]),
        xticklabelsvisible = show_axis_labels,
        xticksvisible = show_axis_labels,
        xticklabelrotation = pi / 4,
        xgridvisible = false,
        yticks = show_axis_labels ? (1:ny, namesY) : (Float64[], String[]),
        yticklabelsvisible = show_axis_labels,
        yticksvisible = show_axis_labels,
        ygridvisible = false,
        aspect = Makie.DataAspect(),
        valign = :top, halign = :left,
        alignmode = Makie.Outside(0))
    Makie.hidespines!(ax)
    abs1 = is_abstract_axis.(model.axes[1])
    abs2 = is_abstract_axis.(model.axes[2])
    cols = Matrix{Makie.RGBAf}(undef, nx, ny)
    for i in 1:nx, j in 1:ny
        c = color_for(model, model.grid[i, j])
        cols[i, j] = (abs1[i] || abs2[j]) ? fade(c) : c
    end
    Makie.image!(ax, (0.5, nx + 0.5), (0.5, ny + 0.5), cols; interpolate = false)
    big || cell_borders!(ax, nx, ny)
    block_separators!(ax, model, nx, ny)
    # Highlight: outer boundary of cells matching `hovered` (only the edges
    # that border a non-matching cell are drawn). Gives a single outline
    # around the union of matching cells, even for disjoint regions.
    hl_segs_2d = Makie.lift(hovered) do h
        _highlight_outline(model.grid, h, nx, ny)
    end
    Makie.linesegments!(ax, hl_segs_2d; color = (:white, 0.95), linewidth = 4)
    Makie.linesegments!(ax, hl_segs_2d; color = :black, linewidth = 1.5)
    Makie.limits!(ax, 0.5, nx + 0.5, 0.5, ny + 0.5)
    Makie.on(Makie.events(ax.scene).mouseposition) do _
        if Makie.is_mouseinside(ax.scene)
            p = Makie.mouseposition(ax.scene)
            i = round(Int, p[1]); j = round(Int, p[2])
            if 1 <= i <= nx && 1 <= j <= ny
                v = model.grid[i, j]
                hovered[] = v
                info[] = describe_cell(model, v, (model.axes[1][i], model.axes[2][j]))
                infocolor[] = color_for(model, v)
                return
            end
        end
        hovered[] = 0; info[] = HINT; infocolor[] = Makie.RGBAf(0, 0, 0, 0)
    end
    return ax
end

function plot_3d!(pos, model, hovered, info, infocolor)
    nx, ny, nz = size(model.grid)
    namesX = typelabel.(model.axes[1])
    namesY = typelabel.(model.axes[2])
    namesZ = typelabel.(model.axes[3])
    pitch = 1.9          # centre-to-centre spacing of the arg₁ slices
    thick = 0.7          # arg₁ thickness of each slice (< pitch ⇒ a visible gap)
    cellalpha = 0.85     # slightly translucent so neighbours behind show through

    abs1 = is_abstract_axis.(model.axes[1])
    abs2 = is_abstract_axis.(model.axes[2])
    abs3 = is_abstract_axis.(model.axes[3])
    pts = Makie.Point3f[]; cols = Makie.RGBAf[]
    cellinfo = Tuple{Int,NTuple{3,Any}}[]
    for i in 1:nx, j in 1:ny, k in 1:nz
        v = model.grid[i, j, k]
        v == 0 && continue                       # gap for uncovered cells
        c = color_for(model, v)
        a = cellalpha * ((abs1[i] || abs2[j] || abs3[k]) ? ABSTRACT_ALPHA : 1.0)
        push!(pts, Makie.Point3f(i * pitch, j, k))
        push!(cols, Makie.RGBAf(c.r, c.g, c.b, c.alpha * a))
        push!(cellinfo, (v, (model.axes[1][i], model.axes[2][j], model.axes[3][k])))
    end

    ax = Makie.Axis3(pos;
        title = "$(funcname(model.f))(arg₁, arg₂, arg₃)",
        xlabel = "arg₁", ylabel = "arg₂", zlabel = "arg₃",
        xticks = (pitch .* (1:nx), namesX), yticks = (1:ny, namesY),
        zticks = (1:nz, namesZ), aspect = :data,
        # `:fitzoom` (Axis3's default) lets scroll move the camera inside the
        # data box, which makes the axis frame appear to cut through the cubes.
        # `:fit` keeps the data framed at all times; rotation still works and
        # hovering is the primary drill-in interaction anyway.
        viewmode = :fit,
        # Give tick labels room to live outside the box.
        protrusions = 60)
    # Pad the limits so the outermost cubes don't sit flush against the axis
    # frame (the cube extends ±thick/2 in x and ±0.5 in y/z from each centre).
    Makie.limits!(ax,
        (0.5 * pitch, (nx + 0.5) * pitch),
        (0.3, ny + 0.7),
        (0.3, nz + 0.7))
    if !isempty(pts)
        mp = Makie.meshscatter!(ax, pts;
            marker = Makie.Rect3f(Makie.Vec3f(-0.5), Makie.Vec3f(1)),
            markersize = Makie.Vec3f(thick, 1.0, 1.0), color = cols,
            transparency = true)
        Makie.on(Makie.events(ax.scene).mouseposition) do _
            if Makie.is_mouseinside(ax.scene)
                plt, idx = Makie.pick(ax.scene)
                if plt === mp && 1 <= idx <= length(cellinfo)
                    v, types = cellinfo[idx]
                    hovered[] = v
                    info[] = describe_cell(model, v, types)
                    infocolor[] = color_for(model, v)
                    return
                end
            end
            hovered[] = 0; info[] = HINT; infocolor[] = Makie.RGBAf(0, 0, 0, 0)
        end
    end
    return ax
end

function plot_main!(pos, model, hovered, info, infocolor;
                    show_title::Bool = true, show_axis_labels::Bool = false)
    model.ndims == 1 && return plot_1d!(pos, model, hovered, info, infocolor;
                                        show_title, show_axis_labels)
    model.ndims == 2 && return plot_2d!(pos, model, hovered, info, infocolor;
                                        show_title, show_axis_labels)
    return plot_3d!(pos, model, hovered, info, infocolor)
end

# --- custom legend (with hover highlight) -----------------------------------

"""Number of (columns, rows) for `n` legend entries, capping rows so a
many-method function wraps into columns instead of a tall list."""
function legend_layout(n::Int)
    maxrows = 8
    ncols = max(1, cld(n, maxrows))
    return ncols, cld(n, ncols)
end

function make_legend!(pos, model, rows, hovered, infocolor, v2r)
    n = length(rows)
    ncols, nrows = legend_layout(n)
    colw = 1 / ncols
    ax = Makie.Axis(pos; title = "Methods of $(funcname(model.f))",
        titlealign = :left, titlesize = 13, titlegap = 4)
    Makie.hidedecorations!(ax); Makie.hidespines!(ax)

    entrypos(idx) = ((idx - 1) ÷ nrows * colw, Float64(nrows - (idx - 1) % nrows))
    # Inverse of v2r: legend row → grid value, used to push hovers from the
    # legend back into `hovered` (which other components read).
    r2v = Dict{Int,Int}(r => v for (v, r) in v2r)

    # `hovered` is the *grid value* currently in focus; translate it to a
    # legend-row index via v2r so the bar highlight lands on the right row.
    hl = Makie.lift(hovered) do h
        rowidx = get(v2r, h, 0)
        if 1 <= rowidx <= n
            x0, y = entrypos(rowidx)
            Makie.Rect2f(x0, y - 0.45, colw, 0.9)
        else
            Makie.Rect2f(-9.0, -9.0, 1.0e-3, 1.0e-3)
        end
    end
    fillc = Makie.lift(c -> Makie.RGBAf(c.r, c.g, c.b, 0.35 * c.alpha), infocolor)
    Makie.poly!(ax, hl; color = fillc, strokecolor = infocolor, strokewidth = 2)

    for (idx, (col, label)) in enumerate(rows)
        x0, y = entrypos(idx)
        Makie.poly!(ax, Makie.Rect2f(x0 + 0.006, y - 0.32, 0.018, 0.64);
            color = col, strokecolor = :gray50, strokewidth = 1)
        Makie.text!(ax, x0 + 0.03, y; text = label, align = (:left, :center), fontsize = 11)
    end
    Makie.xlims!(ax, 0, 1); Makie.ylims!(ax, 0.4, nrows + 0.6)

    # Hovering a legend row updates `hovered` with that row's grid value,
    # which drives the bidirectional highlight on the grid cells.
    Makie.on(Makie.events(ax.scene).mouseposition) do _
        Makie.is_mouseinside(ax.scene) || return
        p = Makie.mouseposition(ax.scene)
        col_i = clamp(floor(Int, p[1] / colw), 0, ncols - 1)
        # y is in [0.4, nrows+0.6]; row 1 sits at y=nrows, row 2 at y=nrows-1, ...
        rowy = nrows - round(Int, p[2]) + 1
        idx = col_i * nrows + rowy
        if 1 <= idx <= n
            v = get(r2v, idx, 0)
            v == 0 && return                # status rows w/o grid mapping
            hovered[] = v
            infocolor[] = color_for(model, v)
        end
    end
    return ax
end
