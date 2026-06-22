# Generates the README images. Run with a backend available, e.g.:
#   julia -e 'using Pkg; Pkg.activate(mktempdir()); Pkg.develop(path=pwd());
#             Pkg.add("CairoMakie"); include("examples/gen_assets.jl")'
using CairoMakie
using DispatchDisplay

addmul(x::Int,    y::Int)    = x * y
addmul(x::Integer, y::Integer) = x + y
addmul(x::Real,   y::Real)   = float(x) + float(y)
addmul(x::String, y::String) = x * y
addmul(x::Int,    y::String) = string(x, y)

assets = joinpath(@__DIR__, "..", "assets")
mkpath(assets)

# Nested brackets: Integer ⊂ Real spanning the numeric axis types.
d2 = dispatchdisplay(addmul, [Int, Bool, Float64, String], [Int, Bool, Float64, String])
save(joinpath(assets, "demo_2d.png"), d2.figure)

box(x::Int,    y::Int,    z::Int)    = 1
box(x::Number, y::Number, z::Number) = 2
box(x::Real,   y::Real,   z::String) = 3
d3 = dispatchdisplay(box, [Int, Float64], [Int, Float64], [Int, Float64, String])
save(joinpath(assets, "demo_3d.png"), d3.figure)

println("wrote assets to ", assets)
