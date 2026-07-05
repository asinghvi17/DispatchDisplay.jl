"""
    DispatchDisplay

Visualise Julia's multiple dispatch as a reactive 1D/2D/3D grid with Makie.

Register a function with [`dispatchdisplay`](@ref) and you get a grid over a
space of candidate argument types.  Each cell is coloured by the method Julia
would actually dispatch to for those concrete types — so concrete methods are
single cells, abstract methods spread across every subtype they cover,
uncovered combinations stay grey, and ambiguities show up red.  Call
[`refresh!`](@ref) (or click the button) after defining new methods.

This package is backend-agnostic: load a Makie backend (e.g. `GLMakie` for an
interactive window, `CairoMakie` for static images) before displaying.
"""
module DispatchDisplay

using Makie
using Colors
using CodeTracking
using LinearAlgebra
using SparseArrays

export dispatchdisplay, refresh!, numeric_types, matrix_types

include("introspection.jl")
include("layout.jl")
include("model.jl")
include("plotting.jl")

"""
    DispatchDisplay.DispatchDisplayResult

Handle returned by [`dispatchdisplay`](@ref).  Holds the live `Makie.Figure`
(field `.figure`) and the current [`DispatchModel`](@ref) snapshot; displays as
the figure and can be re-queried with [`refresh!`](@ref).
"""
mutable struct DispatchDisplayResult
    f::Any
    provided::Union{Nothing,Vector{Vector{Any}}}
    arity::Union{Nothing,Int}
    show_abstracts::Bool
    show_any::Bool
    show_unions::Bool
    # Live UI visibility toggles (flipped by the toggle widgets in the figure).
    show_legend_ui::Bool
    show_panel_ui::Bool
    show_trees_ui::Bool
    figure::Makie.Figure
    model::Base.RefValue{DispatchModel}
    order::IdDict{Method,Int}   # persistent method→colour index (stable colours)
end

function _clear!(fig::Makie.Figure)
    for c in reverse(copy(fig.content))
        try
            delete!(c)
        catch
        end
    end
    try
        Makie.trim!(fig.layout)
    catch
    end
    # Clearing leaves stale row/col size constraints behind (e.g. the old
    # Refresh-button's Fixed height), which would otherwise pin the rebuilt grid
    # to a tiny size. Reset them to Auto so the next render starts clean.
    gl = fig.layout
    nr, nc = size(gl)
    for i in 1:nr
        Makie.rowsize!(gl, i, Makie.Auto())
    end
    for j in 1:nc
        Makie.colsize!(gl, j, Makie.Auto())
    end
    return fig
end

function _render!(d::DispatchDisplayResult)
    fig = d.figure
    _clear!(fig)
    model = d.model[]
    hovered = Makie.Observable(0)                       # legend row to highlight (0 = none)
    info = Makie.Observable(HINT)                       # hover panel text
    infocolor = Makie.Observable(Makie.RGBAf(0, 0, 0, 0))  # hovered tile's colour
    rows, v2r, inline = legend_rows(model)
    nmethods = length(model.methodlist)
    # Past ~16 methods (e.g. a whole operator), a legend is hopeless — drop it
    # and identify methods by hovering instead (a zoomable "dispatch map").
    manymethods = nmethods > 16
    # UI visibility = data-driven default AND user toggle.
    showpanel = d.show_panel_ui && nmethods > 0 && (manymethods || !inline)
    showlegend = d.show_legend_ui && !isempty(rows) && !manymethods
    show_axis_labels = !d.show_trees_ui

    # Top region: grid + linked sibling axes that draw the per-dimension DAG.
    # Everything lives directly in `fig.layout` (no nested GridLayouts — they
    # confuse `_clear!` + Fixed-row reset across refresh cycles). 1D = top
    # tree row + main row. 2D = 2×2 (corner blank / x-tree, y-tree / main).
    # 3D = main only for now; linked Axis3 trees come in a follow-up.
    r = 1
    fname = funcname(model.f)
    # Title gets its own row above the trees so it never collides with
    # Fixed-sized tree rows (axis titles inside a Fixed row tend to clip).
    title_row_used = false
    if model.ndims == 1
        tree1 = model.trees[1]
        showtree = d.show_trees_ui && any(tree1.expandable)
        if showtree
            Makie.Label(fig[1, 1], "$fname(arg₁)";
                fontsize = 16, font = :bold, halign = :center)
            Makie.rowsize!(fig.layout, 1, Makie.Fixed(24.0))
            title_row_used = true
            # Fix the strip's cell size so the tree's label fitting sees the
            # true on-screen cellpx; equal fixed axis widths keep the linked
            # x-coordinates pixel-aligned.
            n1 = length(model.axes[1])
            fw1, fh1 = Tuple(fig.scene.viewport[].widths)
            below_h1 = (showpanel ? 96.0 : 0.0) +
                       (showlegend ? legend_layout(length(rows))[2] * 24.0 + 30.0 : 0.0) +
                       44.0 + 24.0 + 10.0 * 5 + 28.0
            prov1 = max(16.0, (fw1 - 40.0) / n1)
            th = tree_bands(model, 1, prov1; top = true).total
            avail_h1 = max(24.0, fh1 - th - below_h1)
            cell1 = clamp(min((fw1 - 40.0) / n1, avail_h1), 16.0, 96.0)
            th = tree_bands(model, 1, cell1; top = true).total
            ax_main = plot_main!(fig[3, 1], model, hovered, info, infocolor;
                                 show_title = false, show_axis_labels = false)
            ax_tree = tree_axis_top!(fig[2, 1], model, ax_main; cellpx = cell1)
            ax_main.width = n1 * cell1
            ax_tree.width = n1 * cell1
            Makie.rowsize!(fig.layout, 2, Makie.Fixed(th))
            Makie.rowsize!(fig.layout, 3, Makie.Fixed(cell1))
            Makie.rowgap!(fig.layout, 2, 2)
            r = 4
        else
            plot_main!(fig[1, 1], model, hovered, info, infocolor;
                       show_axis_labels = show_axis_labels)
        end
    elseif model.ndims == 2
        tx, ty = model.trees[1], model.trees[2]
        showtx = d.show_trees_ui && any(tx.expandable)
        showty = d.show_trees_ui && any(ty.expandable)
        # Title in its own dedicated row; tree row is just the tree.
        title_h = 24.0
        main_row = showtx ? 3 : 2
        main_col = showty ? 2 : 1
        Makie.Label(fig[1, main_col], "$fname(arg₁, arg₂)";
            fontsize = 16, font = :bold, halign = :center)
        Makie.rowsize!(fig.layout, 1, Makie.Fixed(title_h))
        title_row_used = true
        nx, ny = length(model.axes[1]), length(model.axes[2])
        # Pixel budget for the grid: figure size minus tree bands and the
        # below-grid stack; `DataAspect` keeps cells square. Bands and cellpx
        # are mutually dependent (45° label rotation kicks in on narrow
        # columns), so size in two passes.
        fw, fh = Tuple(fig.scene.viewport[].widths)
        below_h = (showpanel ? 96.0 : 0.0) +
                  (showlegend ? legend_layout(length(rows))[2] * 24.0 + 30.0 : 0.0) +
                  44.0 +                                    # toggle row + refresh
                  title_h +                                 # title row
                  10.0 * 6 +                                # default rowgaps
                  28.0                                      # figure top+bottom padding
        prov = max(16.0, (fw - 30.0) / nx)
        xt_h = showtx ? tree_bands(model, 1, prov; top = true).total : 0.0
        yt_w = showty ? tree_bands(model, 2, prov; top = false).total : 0.0
        avail_w = max(80.0, fw - yt_w - 30.0)
        avail_h = max(80.0, fh - xt_h - below_h)
        cellpx = max(16.0, min(avail_w / nx, avail_h / ny))
        xt_h = showtx ? tree_bands(model, 1, cellpx; top = true).total : 0.0
        yt_w = showty ? tree_bands(model, 2, cellpx; top = false).total : 0.0
        ax_main = plot_main!(fig[main_row, main_col], model, hovered, info, infocolor;
                             show_title = false,
                             show_axis_labels = show_axis_labels)
        if showtx
            tree_axis_top!(fig[2, main_col], model, ax_main; cellpx = cellpx)
            Makie.rowsize!(fig.layout, 2, Makie.Fixed(xt_h))
            Makie.rowgap!(fig.layout, 2, 2)
        end
        if showty
            tree_axis_left!(fig[main_row, 1], model, ax_main; cellpx = cellpx)
            Makie.colsize!(fig.layout, 1, Makie.Fixed(yt_w))
            Makie.colgap!(fig.layout, 1, 2)
        end
        Makie.colsize!(fig.layout, main_col, Makie.Fixed(cellpx * nx))
        Makie.rowsize!(fig.layout, main_row, Makie.Fixed(cellpx * ny))
        r = main_row + 1
    else  # 3D — main only for now
        plot_main!(fig[1, 1], model, hovered, info, infocolor)
        r = 2
    end
    # Below-grid stuff spans both columns (so the hover panel/legend cover the
    # full width when a y-tree column is present).

    span = model.ndims == 2 && d.show_trees_ui && any(model.trees[2].expandable) ? (1:2) : (1:1)
    if showpanel
        # A tinted box behind the text, coloured by the hovered tile's method.
        boxc = Makie.lift(c -> Makie.RGBAf(c.r, c.g, c.b, 0.18 * c.alpha), infocolor)
        Makie.Box(fig[r, span]; color = boxc, strokecolor = infocolor, strokewidth = 2)
        Makie.Label(fig[r, span], info; halign = :left, justification = :left,
            fontsize = 12, tellheight = false, tellwidth = false,
            padding = (10, 10, 6, 6))
        Makie.rowsize!(fig.layout, r, Makie.Fixed(96.0)); r += 1
    end
    if showlegend
        make_legend!(fig[r, span], model, rows, hovered, infocolor, v2r)
        Makie.rowsize!(fig.layout, r, Makie.Fixed(legend_layout(length(rows))[2] * 24 + 30.0))
        r += 1
    end
    # Toggle row: small switches to hide/show trees, legend, hover panel —
    # plus the Refresh button. Toggling re-renders without rebuilding the
    # model; Refresh re-queries methods(f) (use it after defining new methods).
    ctrl = Makie.GridLayout(fig[r, span]; tellheight = false)
    trees_t  = Makie.Toggle(ctrl[1, 1]; active = d.show_trees_ui,  width = 28)
    Makie.Label(ctrl[1, 2], "trees"; halign = :left)
    legend_t = Makie.Toggle(ctrl[1, 3]; active = d.show_legend_ui, width = 28)
    Makie.Label(ctrl[1, 4], "legend"; halign = :left)
    panel_t  = Makie.Toggle(ctrl[1, 5]; active = d.show_panel_ui,  width = 28)
    Makie.Label(ctrl[1, 6], "panel"; halign = :left)
    btn = Makie.Button(ctrl[1, 7]; label = "⟳ Refresh")
    Makie.colgap!(ctrl, 6)
    Makie.rowsize!(fig.layout, r, Makie.Fixed(40.0))
    Makie.on(trees_t.active) do v
        v == d.show_trees_ui && return
        d.show_trees_ui = v; _render!(d)
    end
    Makie.on(legend_t.active) do v
        v == d.show_legend_ui && return
        d.show_legend_ui = v; _render!(d)
    end
    Makie.on(panel_t.active) do v
        v == d.show_panel_ui && return
        d.show_panel_ui = v; _render!(d)
    end
    Makie.on(btn.clicks) do _
        refresh!(d)
    end
    return d
end

"""
    dispatchdisplay(f, types...; size=(960, 680)) -> DispatchDisplayResult

Display the methods of `f` as a grid.

`types` is one vector of candidate types per argument, e.g.

```julia
dispatchdisplay(foo, [Int, Float64, String], [Int, Float64, String])
```

giving a 2D grid.  Provide one vector for a 1D strip and three for a 3D sliced
view.  When `types` are provided, they are used as-is — abstract entries are
allowed and rendered with a faded fill.

With no `types`, the axis types are inferred from `f`'s method signatures and
the dimensionality from its most common arity — pass `arity` to force it. By
default this includes both concrete types and the abstract types that appear in
the signatures (so every method shows up, including the catch-all `Any` cell
when a method uses it). Toggles (inferred axes only — `provided` types are
never filtered):

* `show_abstracts=false` — concrete types only.
* `show_any=false` — drop the `Any` cell.
* `show_unions=false` — don't add each `Union{...}` signature as its own axis
  cell (the constituents are still expanded onto the axis either way).

Hover a cell to highlight the owning method in the legend (and, when method
sources are long, show the source). Cells whose axis type is abstract are
rendered with reduced alpha. Method colours are stable: defining new methods
never reshuffles existing ones.
"""
function dispatchdisplay(f, types...; arity = nothing, size = nothing,
                         show_abstracts::Bool = true, show_any::Bool = true,
                         show_unions::Bool = true)
    provided = isempty(types) ? nothing :
               Vector{Vector{Any}}([collect(Any, t) for t in types])
    order = IdDict{Method,Int}()
    model = build_model(f, provided; order = order, arity = arity,
                        show_abstracts = show_abstracts, show_any = show_any,
                        show_unions = show_unions)
    # A 1D strip needs far less height than a 2D/3D grid.
    fsize = size !== nothing ? size :
            model.ndims == 1 ? (660, ceil(Int, default_1d_height(model))) :
            (660, 880)
    fig = Makie.Figure(; size = fsize, figure_padding = 14)
    d = DispatchDisplayResult(f, provided, arity,
                              show_abstracts, show_any, show_unions,
                              true, true, true,           # UI: legend / panel / trees all on
                              fig, Ref(model), order)
    _render!(d)
    return d
end

"""
    refresh!(d::DispatchDisplayResult) -> d

Re-query `f`'s methods, re-expand the type space, and redraw in place.
"""
function refresh!(d::DispatchDisplayResult)
    d.model[] = build_model(d.f, d.provided; order = d.order, arity = d.arity,
                            show_abstracts = d.show_abstracts, show_any = d.show_any,
                            show_unions = d.show_unions)
    _render!(d)
    return d
end

# Behave like the underlying figure when displayed, but stay informative at the REPL.
Base.display(d::DispatchDisplayResult) = display(d.figure)
function Base.show(io::IO, ::MIME"text/plain", d::DispatchDisplayResult)
    m = d.model[]
    print(io, "DispatchDisplayResult(", d.f, ", ", m.ndims, "D, ",
        length(m.methodlist), " method(s))")
end
for M in (MIME"image/png", MIME"image/svg+xml", MIME"text/html", MIME"application/vnd.julia-vscode.diagnostics")
    @eval Base.show(io::IO, m::$M, d::DispatchDisplayResult) = show(io, m, d.figure)
    @eval Base.showable(m::$M, d::DispatchDisplayResult) = showable(m, d.figure)
end

end # module
