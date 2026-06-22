# Run with an interactive backend:  julia --project=. examples/demo.jl
using GLMakie          # interactive window; swap for CairoMakie to save images
using DispatchDisplay

# A small operator with a mix of concrete and abstract methods.
combine(x::Int,      y::Int)      = x + y
combine(x::Integer,  y::Integer)  = x - y
combine(x::Real,     y::Real)     = float(x) + float(y)
combine(x::String,   y::String)   = x * y
combine(x::Int,      y::String)   = string(x, y)

# 2D grid over a chosen type space. Watch:
#   * concrete (Int,Int) and (Int,String) are single cells
#   * (Real,Real) / (Integer,Integer) spread across their numeric subtypes,
#     with nested `Real`/`Integer` brackets on the axes
#   * (String,Int) stays grey  -> uncovered (MethodError)
#   * HOVER any cell: the owning method highlights in the legend and its source
#     shows in the panel below the grid
d = dispatchdisplay(combine,
        [Int, Bool, Float64, String],
        [Int, Bool, Float64, String])
display(d)

# Define a new method, then refresh (or click ⟳) to see the grid update.
# Existing method colours stay put; the new method gets a fresh colour:
#   combine(x::Bool, y::Bool) = xor(x, y)
#   refresh!(d)
