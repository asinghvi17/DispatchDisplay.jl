# The simplest possible example.
#   julia --project=. examples/simple.jl
using GLMakie            # interactive window (use CairoMakie to save a PNG instead)
using DispatchDisplay

# Three methods: one concrete, one abstract, one on strings.
area(x::Int)     = x^2
area(x::Real)    = float(x)^2
area(x::String)  = length(x)

# Show a 1D grid over four candidate types.
d = dispatchdisplay(area, [Int, Float64, Bool, String])
display(d)
