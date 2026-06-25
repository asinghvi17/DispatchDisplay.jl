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

# --- DAG rendering on a linked sibling axis -----------------------------------
#
# Each grid axis-dimension gets its own `tree_axis_*!` Axis that shares its data
# coordinate with the main grid via `linkxaxes!`/`linkyaxes!`. The DAG is drawn
# as squared `linesegments!` connectors on this sibling axis, with `text!`
# labels (gray for abstracts/Unions) at each node. Parent rests at depth
# `tree_depth - depth[p] + 1`, so shallow parents (close to the root) sit
# furthest from the grid, hugging the outside.

const TREE_COLOR = Makie.RGBAf(0.45, 0.45, 0.45, 1.0)
const TREE_LINEWIDTH = 1.2
const LABEL_CONCRETE       = Makie.RGBAf(0.10, 0.10, 0.10, 1.0)   # concrete + has method
const LABEL_NONCONCRETE    = Makie.RGBAf(0.35, 0.35, 0.35, 1.0)   # abstract/Union + has method
const LABEL_INTERMEDIATE   = Makie.RGBAf(0.55, 0.55, 0.55, 1.0)   # no own method (pure intermediate)
const TREE_NAME_MAXLEN = 22          # label truncation length per node

"""Tree axis depth (the deepest path length), used to size the sibling axis."""
tree_height(t::AxisTree) = tree_depth(t) + 1

"""Label colour tier — concrete-with-method darkest, intermediate lightest."""
function _label_color(@nospecialize(T), has_method::Bool)
    has_method || return LABEL_INTERMEDIATE
    is_abstract_axis(T) ? LABEL_NONCONCRETE : LABEL_CONCRETE
end

"""
    _tree_node_positions(tree, axis_count) -> Vector{Float64}

Position each tree node along its axis dimension:
* axis leaves sit at their `axis_idx` (integer).
* floating nodes sit at the centroid of their *axis-leaf* descendants, with a
  small offset when the centroid coincides exactly with an axis leaf's
  position (otherwise the floating node's label would sit on top of the leaf
  label — common for `Mammal → Dog`-style chains where the floating node has
  one axis-leaf descendant).
* Nodes without any axis-leaf descendant fall back to centroid of all
  descendants, then to the midpoint of the axis.
"""
function _tree_node_positions(tree::AxisTree, axis_count::Int)
    n = length(tree.nodes)
    pos = fill(NaN, n)
    for k in 1:n
        ai = tree.axis_idx[k]
        ai === nothing || (pos[k] = float(ai))
    end
    function leaf_descendants(k)
        seen = Set{Int}()
        q = Int[k]
        while !isempty(q)
            j = popfirst!(q)
            for c in tree.children[j]
                c in seen && continue
                push!(seen, c)
                push!(q, c)
            end
        end
        return seen
    end
    # Track leaf-axis indices that already have a floating node directly on
    # them, so chained floating nodes (e.g. Number → Real → Float64) get
    # progressively larger offsets and stack visibly instead of all colliding.
    nudge_count = Dict{Int,Int}()
    for k in 1:n
        isnan(pos[k]) || continue
        ds = leaf_descendants(k)
        leaves = [tree.axis_idx[d] for d in ds if tree.axis_idx[d] !== nothing]
        if length(leaves) == 1
            li = leaves[1]
            offset = 0.35 + 0.18 * get(nudge_count, li, 0)
            pos[k] = li - offset
            nudge_count[li] = get(nudge_count, li, 0) + 1
        elseif !isempty(leaves)
            pos[k] = sum(leaves) / length(leaves)
        elseif !isempty(ds)
            pos[k] = sum(d for d in ds) / length(ds)
        else
            pos[k] = (1 + axis_count) / 2
        end
    end
    return pos
end

_push_seg!(segs, x1, y1, x2, y2, swap::Bool) = swap ?
    (push!(segs, Makie.Point2f(y1, x1), Makie.Point2f(y2, x2))) :
    (push!(segs, Makie.Point2f(x1, y1), Makie.Point2f(x2, y2)))

# Reserved data-unit "label band" above each x-tree node: drops stop at the
# top of this band so the connector points down to the label without slicing
# through it. Sized to comfortably clear the default ~14px label height with
# the per-depth pixel sizing used in `_render!`.
const LABEL_BAND = 0.35

"""DAG edge segments — squared connectors from parent's `(pos, depth)` over a
cross-bar at `depth - 0.5` down toward each child. Drops stop above the
child's `LABEL_BAND` so the connector visually points to the label without
running through it."""
function _tree_edge_segments(tree::AxisTree, node_pos::Vector{Float64}; swap::Bool)
    D = tree_depth(tree)
    segs = Makie.Point2f[]
    for p in 1:length(tree.children)
        ch = tree.children[p]
        isempty(ch) && continue
        depth_p = float(D - tree.depth[p] + 1)
        cb = depth_p - 0.5
        xp = node_pos[p]
        _push_seg!(segs, xp, depth_p, xp, cb, swap)
        xmin = float(min(xp, minimum(node_pos[c] for c in ch)))
        xmax = float(max(xp, maximum(node_pos[c] for c in ch)))
        _push_seg!(segs, xmin, cb, xmax, cb, swap)
        for c in ch
            drop_end = float(D - tree.depth[c] + 1) + LABEL_BAND
            # Don't draw a degenerate-or-inverted drop when the cross-bar
            # already sits inside the label band (deep trees, tight spacing).
            drop_end < cb || continue
            _push_seg!(segs, node_pos[c], cb, node_pos[c], drop_end, swap)
        end
    end
    return segs
end

"""Create a sibling x-tree `Axis` above `main`, sharing its x-coordinate.

Tree depth runs upward (root at the top, leaves just above the grid). Labels
sit above their nodes — no rotation, since each label has a full row of its
own and the depth-spacing keeps them from stacking vertically.
"""
function tree_axis_top!(pos, tree::AxisTree, axis_count::Int, main::Makie.Axis)
    D = tree_depth(tree)
    ax = Makie.Axis(pos;
        xticks = (Float64[], String[]), xticklabelsvisible = false,
        xticksvisible = false, xgridvisible = false,
        yticks = (Float64[], String[]), yticklabelsvisible = false,
        yticksvisible = false, ygridvisible = false)
    Makie.hidespines!(ax)
    Makie.linkxaxes!(main, ax)
    node_pos = _tree_node_positions(tree, axis_count)
    segs = _tree_edge_segments(tree, node_pos; swap = false)
    isempty(segs) ||
        Makie.linesegments!(ax, segs; color = TREE_COLOR, linewidth = TREE_LINEWIDTH)
    for k in 1:length(tree.nodes)
        T = tree.nodes[k]
        T isa Type || continue
        y = float(D - tree.depth[k] + 1)
        Makie.text!(ax, node_pos[k], y;
            text = _shorten(typelabel(T); maxlen = TREE_NAME_MAXLEN),
            color = _label_color(T, tree.has_method[k]),
            align = (:center, :bottom), fontsize = 11,
            offset = (0.0f0, 4.0f0))   # small gap from the connector line
    end
    Makie.ylims!(ax, 0.5, D + 1.8)
    return ax
end

"""Create a sibling y-tree `Axis` to the left of `main`, sharing its y.

Depth uses *negative* x coordinates so the root naturally sits leftmost
(furthest from the grid) without flipping the axis. Labels are right-aligned
with a small pixel gap so they don't run into the connector line.
"""
function tree_axis_left!(pos, tree::AxisTree, axis_count::Int, main::Makie.Axis)
    D = tree_depth(tree)
    ax = Makie.Axis(pos;
        yticks = (Float64[], String[]), yticklabelsvisible = false,
        yticksvisible = false, ygridvisible = false,
        xticks = (Float64[], String[]), xticklabelsvisible = false,
        xticksvisible = false, xgridvisible = false)
    Makie.hidespines!(ax)
    Makie.linkyaxes!(main, ax)
    node_pos = _tree_node_positions(tree, axis_count)
    # Flip depths into negative x so the root (depth 0) is leftmost and leaves
    # sit just to the left of the grid. The edge-segment helper consumes the
    # same "tree depth coord" used for label placement, so we flip there too.
    segs = Makie.Point2f[]
    for p in 1:length(tree.children)
        ch = tree.children[p]
        isempty(ch) && continue
        xp = -float(D - tree.depth[p] + 1)
        cb = xp + 0.5
        push!(segs, Makie.Point2f(xp, node_pos[p]), Makie.Point2f(cb, node_pos[p]))
        ymin = float(min(node_pos[p], minimum(node_pos[c] for c in ch)))
        ymax = float(max(node_pos[p], maximum(node_pos[c] for c in ch)))
        push!(segs, Makie.Point2f(cb, ymin), Makie.Point2f(cb, ymax))
        for c in ch
            xc = -float(D - tree.depth[c] + 1)
            push!(segs, Makie.Point2f(cb, node_pos[c]), Makie.Point2f(xc, node_pos[c]))
        end
    end
    isempty(segs) ||
        Makie.linesegments!(ax, segs; color = TREE_COLOR, linewidth = TREE_LINEWIDTH)
    for k in 1:length(tree.nodes)
        T = tree.nodes[k]
        T isa Type || continue
        x = -float(D - tree.depth[k] + 1)
        # Label baseline sits a few px above the stalk so the horizontal
        # connector at y=node_pos doesn't slice through the text.
        Makie.text!(ax, x, node_pos[k];
            text = _shorten(typelabel(T); maxlen = TREE_NAME_MAXLEN),
            color = _label_color(T, tree.has_method[k]),
            align = (:right, :bottom), fontsize = 11,
            offset = (-4.0f0, 3.0f0))
    end
    # Left pad enough for the widest *root-level* label (those extend furthest
    # left). Char-to-data-unit is a heuristic; the figure colsize compensates.
    max_root_chars = 0
    for k in 1:length(tree.nodes)
        T = tree.nodes[k]
        T isa Type || continue
        tree.depth[k] == 0 || continue
        max_root_chars = max(max_root_chars,
            length(_shorten(typelabel(T); maxlen = TREE_NAME_MAXLEN)))
    end
    Makie.xlims!(ax, -(D + 1 + 0.4 * max_root_chars), -0.3)
    return ax
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

function plot_1d!(pos, model, hovered, info, infocolor, v2r)
    n = length(model.axes[1])
    names = typelabel.(model.axes[1])
    ax = Makie.Axis(pos;
        title = "$(funcname(model.f))(arg₁)",
        xticks = (1:n, names), xticklabelrotation = pi / 4,
        xgridvisible = false, ygridvisible = false,
        yticksvisible = false, yticklabelsvisible = false,
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
    Makie.limits!(ax, 0.5, n + 0.5, 0.5, 1.5)
    Makie.on(Makie.events(ax.scene).mouseposition) do _
        if Makie.is_mouseinside(ax.scene)
            p = Makie.mouseposition(ax.scene)
            i = round(Int, p[1])
            if 1 <= i <= n && 0.5 <= p[2] <= 1.5
                v = model.grid[i]
                hovered[] = get(v2r, v, 0)
                info[] = describe_cell(model, v, (model.axes[1][i],))
                infocolor[] = color_for(model, v)
                return
            end
        end
        hovered[] = 0; info[] = HINT; infocolor[] = Makie.RGBAf(0, 0, 0, 0)
    end
    return ax
end

function plot_2d!(pos, model, hovered, info, infocolor, v2r)
    nx, ny = length(model.axes[1]), length(model.axes[2])
    namesX = typelabel.(model.axes[1])
    namesY = typelabel.(model.axes[2])
    big = nx * ny > 600
    ax = Makie.Axis(pos;
        title = "$(funcname(model.f))(arg₁, arg₂)", xlabel = "arg₁", ylabel = "arg₂",
        xticks = (1:nx, namesX), yticks = (1:ny, namesY),
        xticklabelrotation = pi / 4, xgridvisible = false, ygridvisible = false,
        aspect = Makie.DataAspect())
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
    Makie.limits!(ax, 0.5, nx + 0.5, 0.5, ny + 0.5)
    (nx > MAXLABELS || ny > MAXLABELS) && lod_ticks!(ax, namesX, namesY)
    Makie.on(Makie.events(ax.scene).mouseposition) do _
        if Makie.is_mouseinside(ax.scene)
            p = Makie.mouseposition(ax.scene)
            i = round(Int, p[1]); j = round(Int, p[2])
            if 1 <= i <= nx && 1 <= j <= ny
                v = model.grid[i, j]
                hovered[] = get(v2r, v, 0)
                info[] = describe_cell(model, v, (model.axes[1][i], model.axes[2][j]))
                infocolor[] = color_for(model, v)
                return
            end
        end
        hovered[] = 0; info[] = HINT; infocolor[] = Makie.RGBAf(0, 0, 0, 0)
    end
    return ax
end

function plot_3d!(pos, model, hovered, info, infocolor, v2r)
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
                    hovered[] = get(v2r, v, 0)
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

function plot_main!(pos, model, hovered, info, infocolor, v2r)
    model.ndims == 1 && return plot_1d!(pos, model, hovered, info, infocolor, v2r)
    model.ndims == 2 && return plot_2d!(pos, model, hovered, info, infocolor, v2r)
    return plot_3d!(pos, model, hovered, info, infocolor, v2r)
end

# --- custom legend (with hover highlight) -----------------------------------

"""Number of (columns, rows) for `n` legend entries, capping rows so a
many-method function (e.g. `+`) wraps into columns instead of a tall list."""
function legend_layout(n::Int)
    maxrows = 14
    ncols = max(1, cld(n, maxrows))
    return ncols, cld(n, ncols)
end

function make_legend!(pos, model, rows, hovered, infocolor)
    n = length(rows)
    ncols, nrows = legend_layout(n)
    colw = 1 / ncols
    ax = Makie.Axis(pos; title = "Methods of $(funcname(model.f))",
        titlealign = :left, titlesize = 13, titlegap = 4)
    Makie.hidedecorations!(ax); Makie.hidespines!(ax)

    entrypos(idx) = ((idx - 1) ÷ nrows * colw, Float64(nrows - (idx - 1) % nrows))

    hl = Makie.lift(hovered) do h
        if 1 <= h <= n
            x0, y = entrypos(h)
            Makie.Rect2f(x0, y - 0.45, colw, 0.9)
        else
            Makie.Rect2f(-9.0, -9.0, 1.0e-3, 1.0e-3)
        end
    end
    # Highlight the hovered entry in the hovered tile's own colour.
    fillc = Makie.lift(c -> Makie.RGBAf(c.r, c.g, c.b, 0.35 * c.alpha), infocolor)
    Makie.poly!(ax, hl; color = fillc, strokecolor = infocolor, strokewidth = 2)

    for (idx, (col, label)) in enumerate(rows)
        x0, y = entrypos(idx)
        Makie.poly!(ax, Makie.Rect2f(x0 + 0.006, y - 0.32, 0.018, 0.64);
            color = col, strokecolor = :gray50, strokewidth = 1)
        Makie.text!(ax, x0 + 0.03, y; text = label, align = (:left, :center), fontsize = 11)
    end
    Makie.xlims!(ax, 0, 1); Makie.ylims!(ax, 0.4, nrows + 0.6)
    return ax
end
