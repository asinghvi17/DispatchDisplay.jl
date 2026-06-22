# Rock-paper-scissors as multiple dispatch, after Mosè Giordano's classic post:
#   https://giordano.github.io/blog/2017-11-03-rock-paper-scissors/
#
# `play` dispatches on the *types* `Type{Rock}`, … . The grid then shows the
# whole game at a glance: each explicit win-rule is a single cell, the diagonal
# is the `Tie` method, and the mirror-image half is handled by the commutativity
# fallback `play(a, b) = play(b, a)`.
#   julia --project=. examples/rock_paper_scissors.jl
using GLMakie            # interactive window (use CairoMakie to save a PNG)
using DispatchDisplay

abstract type Shape end
struct Rock     <: Shape end
struct Paper    <: Shape end
struct Scissors <: Shape end

play(::Type{Paper}, ::Type{Rock})     = "Paper wins"
play(::Type{Paper}, ::Type{Scissors}) = "Scissors wins"
play(::Type{Rock},  ::Type{Scissors}) = "Rock wins"
play(::Type{T}, ::Type{T}) where {T<:Shape} = "Tie, try again"
play(a::Type{<:Shape}, b::Type{<:Shape}) = play(b, a)   # commutativity fallback

# 3-way grid over the three shapes (note: pass `Type{Rock}`, since that's the
# argument type `play` dispatches on; it's shown on the axes as just `Rock`).
shapes3 = [Type{Rock}, Type{Paper}, Type{Scissors}]
d3 = dispatchdisplay(play, shapes3, shapes3)
display(d3)

# 4-way extension: add a Well that beats Rock and Scissors but loses to Paper.
struct Well <: Shape end
play(::Type{Well}, ::Type{Rock})     = "Well wins"
play(::Type{Well}, ::Type{Scissors}) = "Well wins"
play(::Type{Well}, ::Type{Paper})    = "Paper wins"

shapes4 = [Type{Rock}, Type{Paper}, Type{Scissors}, Type{Well}]
d4 = dispatchdisplay(play, shapes4, shapes4)
display(d4)
