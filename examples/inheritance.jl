# A 2D dispatch grid showing several levels of the type hierarchy at once.
#   julia --project=. examples/inheritance.jl
using GLMakie            # interactive window (use CairoMakie to save a PNG)
using DispatchDisplay

# A small hierarchy, three levels deep:
#
#                     Animal
#                    /      \
#               Mammal       Bird
#               /    \       /    \
#             Dog    Cat  Sparrow  Penguin
abstract type Animal end
abstract type Mammal <: Animal end
abstract type Bird   <: Animal end
struct Dog     <: Mammal end
struct Cat     <: Mammal end
struct Sparrow <: Bird   end
struct Penguin <: Bird   end

# `meets` is overloaded at every level — from the catch-all `Animal` method down
# to a fully concrete `(Dog, Cat)` special case:
meets(a::Animal,  b::Animal)  = "they ignore each other"   # most general
meets(a::Mammal,  b::Mammal)  = "they sniff"               # both mammals
meets(a::Bird,    b::Bird)    = "they flock"               # both birds
meets(a::Dog,     b::Dog)     = "they play"                # concrete pair
meets(a::Dog,     b::Cat)     = "the dog chases the cat"   # concrete pair

# A `Union` method cuts across the hierarchy — `Cat` is a Mammal and `Sparrow`
# is a Bird, so this one method tiles two non-adjacent rows of the grid:
meets(a::Union{Cat, Sparrow}, b::Dog) = "the small one freezes"

# Show the grid over the four concrete species on each axis. Watch:
#   * `Animal` brackets the whole axis; `Mammal` and `Bird` nest inside it
#   * the abstract methods tile broad regions, concrete methods are single cells
#   * (Dog,Cat) and (Dog,Dog) are specialised cells inside the Mammal block
#   * the `Union{Cat,Sparrow}` row paints (Cat,Dog) and (Sparrow,Dog) the same,
#     skipping (Dog,Dog) in between — a stripe abstracts alone can't produce
d = dispatchdisplay(meets,
        [Dog, Cat, Sparrow, Penguin],
        [Dog, Cat, Sparrow, Penguin])
display(d)
