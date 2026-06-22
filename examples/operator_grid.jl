# "Take the arity, not a set of types": visualise a whole operator's dispatch.
#   julia --project=. examples/operator_grid.jl
using GLMakie
using DispatchDisplay

# Zoom needs the interactive GLMakie window — make sure GLMakie is the active
# backend (CairoMakie, if loaded, would give a static image with no zoom) and
# open a real window rather than an inline PNG (VS Code / Jupyter).
GLMakie.activate!(inline = false)
openwin(d) = display(GLMakie.Screen(), d.figure)

# Interactive controls, once a window is open:
#   scroll          zoom toward the cursor
#   left-drag       rubber-band rectangle zoom
#   right-drag      pan
#   Ctrl+left-click reset to full view

# A tidy, readable grid over a curated palette of concrete number types. Each
# cell is coloured by the `+` method that the pair dispatches to; abstract
# methods (`+(::Integer,::Integer)`, `+(::Real,::Real)`, …) show as the colours
# and as subtype brackets over the concrete axes.
numeric = dispatchdisplay(+, numeric_types(), numeric_types())
openwin(numeric)

# The "whole operator" map: infer every concrete argument type from `+`'s 2-arg
# signatures. Large, so it renders as a zoomable dispatch fingerprint — no labels
# until you zoom in (level-of-detail); hover any cell to identify its method.
wholeplus = dispatchdisplay(+; arity = 2)
openwin(wholeplus)

# Works for any operator/function — e.g. `*`, `==`, `isless`:
#   openwin(dispatchdisplay(*; arity = 2))
