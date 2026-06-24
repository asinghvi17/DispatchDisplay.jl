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

# --- brackets (top for arg₁, right for arg₂; opposite the tick labels) -------

bracket_depth(brs) = isempty(brs) ? 0 : maximum(b.depth for b in brs) + 1

function draw_brackets_x!(ax, brs, y0, step)
    for b in brs
        y = y0 + b.depth * step
        Makie.bracket!(ax, b.lo - 0.45, y, b.hi + 0.45, y;
            offset = 1, text = b.label, orientation = :up,
            fontsize = 11, textcolor = :gray25, color = :gray45)
    end
end

function draw_brackets_y!(ax, brs, x0, step)
    for b in brs
        # `:up` with a bottom→top span makes the brace embrace the grid from the
        # left (opening toward the tiles, label on the outside), mirroring the
        # top brackets which embrace from above.
        x = x0 - b.depth * step
        Makie.bracket!(ax, x, b.lo - 0.45, x, b.hi + 0.45;
            offset = 1, text = b.label, orientation = :up, rotation = pi / 2,
            fontsize = 11, textcolor = :gray25, color = :gray45)
    end
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
    names = typelabel.(model.axes[1])
    n = length(names)
    bx = model.brackets[1]
    step = 0.4
    my = bracket_depth(bx) * step + (isempty(bx) ? 0.0 : 0.25)
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
    draw_brackets_x!(ax, bx, 1.55, step)
    Makie.limits!(ax, 0.5, n + 0.5, 0.5, 1.5 + my)
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
    n1 = typelabel.(model.axes[1]); n2 = typelabel.(model.axes[2])
    nx, ny = length(n1), length(n2)
    bx, by = model.brackets[1], model.brackets[2]
    step = 0.4
    # Big grids (e.g. a whole operator) become a zoomable "dispatch map": no
    # brackets/borders, and labels appear only as you zoom in (level-of-detail).
    big = nx * ny > 600
    # The extra room (beyond the bracket stack) holds the outermost bracket's
    # label; scale it a little with the grid size so the label isn't clipped on
    # denser grids (where a data unit maps to fewer pixels).
    pad = 0.45 + 0.04 * max(nx, ny)
    my = (big || isempty(bx)) ? 0.0 : bracket_depth(bx) * step + pad   # top room
    mx = (big || isempty(by)) ? 0.0 : bracket_depth(by) * step + pad   # left room
    # Square cells (DataAspect); the frame is hidden so the letterbox whitespace
    # doesn't read as a gap, and the brackets sit in slim top/left margins.
    ax = Makie.Axis(pos;
        title = "$(funcname(model.f))(arg₁, arg₂)", xlabel = "arg₁", ylabel = "arg₂",
        xticks = (1:nx, n1), yticks = (1:ny, n2),
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
    if !big
        cell_borders!(ax, nx, ny)
        draw_brackets_x!(ax, bx, ny + 0.55, step)
        draw_brackets_y!(ax, by, 0.45, step)
    end
    Makie.limits!(ax, 0.5 - mx, nx + 0.5, 0.5, ny + 0.5 + my)
    (nx > MAXLABELS || ny > MAXLABELS) && lod_ticks!(ax, n1, n2)
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
        zticks = (1:nz, namesZ), aspect = :data)
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
