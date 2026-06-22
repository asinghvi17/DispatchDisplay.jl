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
    showpanel = nmethods > 0 && (manymethods || !inline)
    showlegend = !isempty(rows) && !manymethods

    # Vertically stacked (split-screen friendly): grid → [hover panel] → [legend]
    # → refresh button.
    r = 1
    plot_main!(fig[r, 1], model, hovered, info, infocolor, v2r); r += 1
    if showpanel
        # A tinted box behind the text, coloured by the hovered tile's method.
        boxc = Makie.lift(c -> Makie.RGBAf(c.r, c.g, c.b, 0.18 * c.alpha), infocolor)
        Makie.Box(fig[r, 1]; color = boxc, strokecolor = infocolor, strokewidth = 2)
        Makie.Label(fig[r, 1], info; halign = :left, justification = :left,
            fontsize = 12, tellheight = false, tellwidth = false,
            padding = (10, 10, 6, 6))
        Makie.rowsize!(fig.layout, r, Makie.Fixed(96.0)); r += 1
    end
    if showlegend
        make_legend!(fig[r, 1], model, rows, hovered, infocolor)
        Makie.rowsize!(fig.layout, r, Makie.Fixed(legend_layout(length(rows))[2] * 24 + 30.0))
        r += 1
    end
    btn = Makie.Button(fig[r, 1]; label = "⟳ Refresh", tellwidth = false)
    Makie.rowsize!(fig.layout, r, Makie.Fixed(34.0))
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
view.  Axes always hold **concrete** types only; abstract types appear as method
colours and as subtype brackets, never as cells.

With no `types`, the concrete types are inferred from `f`'s method signatures and
the dimensionality from its most common arity — pass `arity` to force it. This
is the "whole operator" mode, e.g. `dispatchdisplay(+; arity=2)` or, for a tidy
numeric grid, `dispatchdisplay(+, numeric_types(), numeric_types())`.

Hover a cell to highlight the owning method in the legend (and, when method
sources are long, show the source). Method colours are stable: defining new
methods never reshuffles existing ones.
"""
function dispatchdisplay(f, types...; arity = nothing, size = nothing)
    provided = isempty(types) ? nothing :
               Vector{Vector{Any}}([collect(Any, t) for t in types])
    order = IdDict{Method,Int}()
    model = build_model(f, provided; order = order, arity = arity)
    # A 1D strip needs far less height than a 2D/3D grid.
    fsize = size !== nothing ? size :
            model.ndims == 1 ? (660, 400) : (660, 880)
    fig = Makie.Figure(; size = fsize)
    d = DispatchDisplayResult(f, provided, arity, fig, Ref(model), order)
    _render!(d)
    return d
end

"""
    refresh!(d::DispatchDisplayResult) -> d

Re-query `f`'s methods, re-expand the type space, and redraw in place.
"""
function refresh!(d::DispatchDisplayResult)
    d.model[] = build_model(d.f, d.provided; order = d.order, arity = d.arity)
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
