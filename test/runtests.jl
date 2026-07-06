using DispatchDisplay
using DispatchDisplay: build_model, cell_owner, arity, infer_ndims,
    order_types, build_axis_tree, type_chain, arg_types, method_source,
    legend_rows, describe_cell
using CairoMakie  # headless backend for rendering tests
using LinearAlgebra: Adjoint, Transpose
using Test

# A toy function exercising concrete, abstract, and uncovered combinations.
foo(x::Int, y::Int) = 1
foo(x::Number, y::Number) = 2
foo(x::String, y::String) = 3
foo(x::Int, y::String) = 4

# A function with an unresolved ambiguity at (Int, Int).
amb(x::Int, y) = 1
amb(x, y::Int) = 2

# Rock-paper-scissors style dispatch on `Type{...}` (Giordano's example).
abstract type Shape end
struct Rock  <: Shape end
struct Paper <: Shape end
play(::Type{Paper}, ::Type{Rock}) = "Paper wins"
play(::Type{T}, ::Type{T}) where {T<:Shape} = "Tie"
play(a::Type{<:Shape}, b::Type{<:Shape}) = play(b, a)

@testset "DispatchDisplay" begin

@testset "introspection" begin
    @test infer_ndims(foo) == 2
    @test all(arity(m) == 2 for m in methods(foo))
    @test cell_owner(foo, (Int, Int)) isa Method
    @test cell_owner(foo, (Float64, Float64)) isa Method      # via ::Number
    @test cell_owner(foo, (String, Int)) === :uncovered        # no method
    # Abstract cell where only some concrete subtypes dispatch (Int,String):
    @test cell_owner(foo, (Number, String)) === :partial
end

@testset "ambiguity" begin
    @test cell_owner(amb, (Int, Int)) === :ambiguous
    @test cell_owner(amb, (Int, Float64)) isa Method
end

@testset "layout / subtyping order" begin
    @test type_chain(Int)[1] === Any
    @test type_chain(Int)[end] === Int
    ordered = order_types(Any[String, Int, Float64])
    # Int and Float64 (both Number) should be contiguous, away from String.
    inum = findall(t -> t <: Number, ordered)
    @test inum == collect(minimum(inum):maximum(inum))
end

@testset "axis tree DAG" begin
    # Number is parented above Int and Float64 via the supertype walk;
    # String is its own root. Tree nodes are indexed independently of axis.
    treevec = order_types(Any[Int, Float64, String, Number])
    has_method = trues(length(treevec))
    lookup = T -> findfirst(==(T), treevec)
    t = build_axis_tree(treevec, has_method, lookup)
    numidx = findfirst(==(Number), t.nodes)
    intidx = findfirst(==(Int), t.nodes)
    flidx  = findfirst(==(Float64), t.nodes)
    strix  = findfirst(==(String), t.nodes)
    @test numidx in t.parents[intidx]
    @test numidx in t.parents[flidx]
    @test isempty(t.parents[strix])             # String is a root
    @test isempty(t.parents[numidx])            # Number is a root
    @test sort(t.children[numidx]) == sort([intidx, flidx])

    # Overlap: Int parented by Number AND by Union{Int,String} (both tree
    # nodes, neither contained in the other) → DAG with two edges into Int.
    treevec2 = order_types(Any[Int, Number, Union{Int,String}])
    has2 = trues(length(treevec2))
    t2 = build_axis_tree(treevec2, has2, T -> findfirst(==(T), treevec2))
    numidx2 = findfirst(==(Number), t2.nodes)
    uidx2   = findfirst(==(Union{Int,String}), t2.nodes)
    intidx2 = findfirst(==(Int), t2.nodes)
    @test sort(t2.parents[intidx2]) == sort([numidx2, uidx2])
end

@testset "model grid (explicit types only on axes)" begin
    m = build_model(foo, Vector{Any}[[Int, Float64, String], [Int, Float64, String]])
    @test m.ndims == 2
    @test Set(m.axes[1]) == Set([Int, Float64, String])   # no abstract Number cell
    @test size(m.grid) == (3, 3)
    @test 0 in m.grid          # the uncovered String,Int corner exists
    @test maximum(m.grid) == length(m.methodlist)
    # Provided axes still get tree enrichment: `Number` (and `Real`) show up
    # as floating tree nodes between the concretes. The intermediate chain
    # gives the user the full Number > Real > Int hierarchy.
    @test Number in m.trees[1].nodes
    @test Real in m.trees[1].nodes
    numt = findfirst(==(Number), m.trees[1].nodes)
    realt = findfirst(==(Real), m.trees[1].nodes)
    intt = findfirst(==(Int), m.trees[1].nodes)
    flot = findfirst(==(Float64), m.trees[1].nodes)
    @test realt in m.trees[1].parents[intt]           # Real is Int's parent
    @test realt in m.trees[1].parents[flot]           # ... and Float64's
    @test numt  in m.trees[1].parents[realt]          # Number sits above Real
    @test m.trees[1].axis_idx[numt] === nothing       # tree-only (no grid cell)
    @test m.trees[1].axis_idx[realt] === nothing
end

@testset "bracket tree geometry" begin
    m = build_model(foo, Vector{Any}[[Int, Float64, String], [Int, Float64, String]])
    t = m.trees[1]
    realt = findfirst(==(Real), t.nodes)
    # Real spans the two contiguous numeric columns (axis order is
    # [String, Float64, Int] under the chain-key sort).
    sp = DispatchDisplay._leaf_span(t, realt)
    @test length(sp) == 2 && sp == collect(minimum(sp):maximum(sp))
    # One heavier block separator where the numeric block starts.
    @test DispatchDisplay._block_seps(t, 3) == [1.5]

    # A union's rail spans its member columns and carries the method's colour.
    uf(x::Union{Int,String}) = 1
    uf(x::Float64) = 2
    mu = build_model(uf, nothing)
    tu = mu.trees[1]
    ui = findfirst(==(Union{Int,String}), tu.nodes)
    @test DispatchDisplay._is_unionnode(tu, ui)
    @test length(DispatchDisplay._leaf_span(tu, ui; include_self = false)) == 2
    mi = findfirst(mm -> any(a -> a === Union{Int,String}, arg_types(mm)),
                   mu.methodlist)
    @test DispatchDisplay._union_method_color(mu, Union{Int,String}) == mu.colors[mi]

    # Rail labels compact in tiers as the available span shrinks.
    labs = ["Int8", "Int16", "Int32", "Int64", "Int128"]
    @test DispatchDisplay._rail_label(labs, 10_000.0) ==
          "Int8 ∪ Int16 ∪ Int32 ∪ Int64 ∪ Int128"
    @test DispatchDisplay._rail_label(labs, 130.0) == "Int8 ∪ ⋯ ∪ Int128"
    @test DispatchDisplay._rail_label(labs, 10.0) == "∪ 5 types"

    @test 25 < DispatchDisplay.text_width_px("Mammal", 11) < 60

    # foo's x tree: no unions, two bracket levels (Real inside Number).
    b = DispatchDisplay.tree_bands(m, 1, 96.0; top = true)
    @test isempty(b.lanes)
    @test length(b.bdepths) == 2
    @test b.total > 0
end

@testset "tree interaction" begin
    @test DispatchDisplay._cell_runs([1, 2, 3, 5, 7, 8]) == [1:3, 5:5, 7:8]
    @test DispatchDisplay._cell_runs(Int[]) == UnitRange{Int}[]
    # Veils cover the complement: selecting columns 2:3 of a 4x5 grid dims
    # column 1 and column 4, each as a full-height rect.
    r = DispatchDisplay._veil_rects([2, 3], true, 4, 5)
    @test r == [Rect2f(0.5, 0.5, 1, 5), Rect2f(3.5, 0.5, 1, 5)]
    r = DispatchDisplay._veil_rects([2], false, 4, 5)
    @test r == [Rect2f(0.5, 0.5, 4, 1), Rect2f(0.5, 2.5, 4, 3)]
    # Selecting everything dims nothing.
    @test DispatchDisplay._veil_rects([1, 2, 3, 4], true, 4, 5) ==
          [DispatchDisplay._OFFSCREEN]

    # Hit-boxes from a rendered tree axis: one per leaf, rail and bracket,
    # and point lookup lands on the right element.
    uf2(x::Union{Int,String}, y::Int) = 1
    uf2(x::Float64, y::Int) = 2
    m = build_model(uf2, nothing)
    fig = Figure()
    ax_main = Axis(fig[2, 1])
    tr = DispatchDisplay.tree_axis_top!(fig[1, 1], m, ax_main; cellpx = 96.0)
    t = m.trees[1]
    nleaf = count(k -> DispatchDisplay._is_leafnode(t, k), 1:length(t.nodes))
    @test count(h -> h.kind == :leaf, tr.hits) == nleaf
    @test count(h -> h.kind == :rail, tr.hits) == 1
    rail = only(h for h in tr.hits if h.kind == :rail)
    @test rail.cells ==
          DispatchDisplay._leaf_span(t, findfirst(==(Union{Int,String}), t.nodes);
                                     include_self = false)
    hi = DispatchDisplay._hit_at(tr.hits, (rail.cells[1], rail.rect.origin[2] + 1.0))
    @test tr.hits[hi].kind == :rail
    @test DispatchDisplay._hit_at(tr.hits, (-100.0, -100.0)) == 0

    # Wiring is a no-throw smoke test; pins drive the lifted band rects.
    pins = DispatchDisplay.tree_interaction!(ax_main, length(m.axes[1]), 1,
        [(; ax = tr.ax, hits = tr.hits, cols = true)])
    @test length(pins) == 1
    pins[1][] = hi
    pins[1][] = 0
end

@testset "stable colours when methods are added" begin
    scol(x::Int) = 1
    order = IdDict{Method,Int}()
    m1 = build_model(scol, Vector{Any}[[Int, Float64]]; order = order)
    intm = only(mm for mm in m1.methodlist if arg_types(mm) == Any[Int])
    c_before = m1.colors[findfirst(==(intm), m1.methodlist)]
    scol(x::Float64) = 2       # add a new method (new colour), reuse the order map
    m2 = build_model(scol, Vector{Any}[[Int, Float64]]; order = order)
    c_after = m2.colors[findfirst(==(intm), m2.methodlist)]
    @test c_before == c_after  # the Int method keeps its colour
    @test length(m2.methodlist) == 2
end

@testset "hover helpers" begin
    m = build_model(foo, Vector{Any}[[Int, Float64, String], [Int, Float64, String]])
    rows, v2r, inline = legend_rows(m)
    @test length(rows) == length(m.methodlist) + 1   # methods + uncovered
    @test haskey(v2r, 0)                              # uncovered maps to a row
    @test v2r[1] == 1                                 # first method → first row
    @test inline isa Bool
    s = describe_cell(m, 1, (Int, Int))
    @test occursin("foo", s)
    u = describe_cell(m, 0, (String, Int))
    @test occursin("MethodError", u)
    src = method_source(first(m.methodlist))          # foo is defined in this file
    @test src === nothing || occursin("foo", src)
end

@testset "dispatch on Type{...}" begin
    types = Vector{Any}[[Type{Rock}, Type{Paper}], [Type{Rock}, Type{Paper}]]
    m = build_model(play, types)
    @test size(m.grid) == (2, 2)
    @test all(>(0), m.grid)                 # tie + commutativity fallback cover all
    @test all(isempty, m.trees[1].children) # no noisy Type{<:Shape} tree edges
    @test DispatchDisplay.typelabel(Type{Rock}) == "Rock"
end

@testset "arity mode, concrete axes, numeric palette, LOD" begin
    @test all(T -> T isa Type && isconcretetype(T), numeric_types())
    @test all(T -> T isa Type && isconcretetype(T), matrix_types())

    # Inferred arity mode: axes hold the *concrete* types from signatures
    # (`Int`); abstract types with concrete coverage on the axis (`Number`
    # here, covered by `Int`) move into the tree as floating nodes.
    h(x::Int, y::Int) = 1
    h(x::Number, y::Number) = 2
    m = build_model(h, nothing; arity = 2)
    @test m.ndims == 2
    @test Int in m.axes[1]
    @test !(Number in m.axes[1])               # Number is tree-only (covered by Int)
    @test Number in m.trees[1].nodes           # ...but it IS a tree node
    intidx_t = findfirst(==(Int), m.trees[1].nodes)
    numidx_t = findfirst(==(Number), m.trees[1].nodes)
    @test numidx_t in m.trees[1].parents[intidx_t]   # parent edge in the tree

    # `show_abstracts=false` strips abstracts from both axis and tree.
    mc = build_model(h, nothing; arity = 2, show_abstracts = false)
    @test all(isconcretetype, mc.axes[1])
    @test !(Number in mc.axes[1])
    @test !(Number in mc.trees[1].nodes)

    # `show_any` toggle: by default `Any` participates as a tree root when it
    # appears in a signature (covered by concrete descendants here, so it's
    # tree-only, not on the axis). Opt out with `show_any=false`.
    hany(x::Any) = 1
    hany(x::Int) = 2
    @test  (Any in build_model(hany, nothing; arity = 1).trees[1].nodes)
    @test !(Any in build_model(hany, nothing; arity = 1, show_any = false).trees[1].nodes)

    # Unions in signatures: members are enumerated onto the axis. The Union
    # itself becomes a tree-only node when its members are covered.
    huni(x::Union{Float32,Float64}) = 1
    m1 = build_model(huni, nothing; arity = 1)
    @test  (Float32 in m1.axes[1])
    @test  (Float64 in m1.axes[1])
    @test !(Union{Float32,Float64} in m1.axes[1])         # tree-only, covered
    @test   Union{Float32,Float64} in m1.trees[1].nodes
    # The Union is a parent of each member in the tree.
    ui_t = findfirst(==(Union{Float32,Float64}), m1.trees[1].nodes)
    fi_t = findfirst(==(Float32), m1.trees[1].nodes)
    @test ui_t in m1.trees[1].parents[fi_t]

    # The crashy case: `Union{...} where {T,V<:AbstractVector}` — must just work.
    hpar(x::Union{Adjoint{T,V},Transpose{T,V}}) where {T,V<:AbstractVector} = 1
    hpar(x::Vector) = 2
    @test build_model(hpar, nothing; arity = 1) isa DispatchDisplay.DispatchModel

    # Level-of-detail ticks: hidden when too many are visible, listed otherwise.
    names = string.(1:40)
    @test DispatchDisplay._visible_ticks(0.5, 40.5, names) == (Float64[], String[])
    _, labs = DispatchDisplay._visible_ticks(5.5, 9.5, names)
    @test labs == names[6:9]
end

@testset "no applicable methods" begin
    g(x::Int) = 1
    d = dispatchdisplay(g, [String])     # String is not covered by g(::Int)
    @test isempty(d.model[].methodlist)  # nothing to define → no hover panel
    @test all(==(0), d.model[].grid)     # all uncovered
end

@testset "render 1D/2D/3D" begin
    bar(x::Int) = 1
    bar(x::Number) = 2
    bar(x::AbstractString) = 3
    d1 = dispatchdisplay(bar, [Int, Float64, String, Bool])
    @test d1.model[].ndims == 1
    save(joinpath(@__DIR__, "out_1d.png"), d1.figure)

    d2 = dispatchdisplay(foo, [Int, Float64, String], [Int, Float64, String])
    @test d2.model[].ndims == 2
    save(joinpath(@__DIR__, "out_2d.png"), d2.figure)

    baz(x::Int, y::Int, z::Int) = 1
    baz(x::Number, y::Number, z::Number) = 2
    baz(x::Real, y::Real, z::String) = 3
    d3 = dispatchdisplay(baz, [Int, Float64], [Int, Float64], [Int, Float64, String])
    @test d3.model[].ndims == 3
    save(joinpath(@__DIR__, "out_3d.png"), d3.figure)

    @test isfile(joinpath(@__DIR__, "out_2d.png"))
end

@testset "refresh expands inferred axes" begin
    qux(x::Int) = 1
    d = dispatchdisplay(qux)             # inferred type space (no explicit types)
    @test d.model[].axes[1] == Any[Int]
    qux(x::Float64) = 2                  # new method on a new concrete type
    refresh!(d)
    @test Float64 in d.model[].axes[1]   # inferred axes grew to include it
end

end # outer testset
