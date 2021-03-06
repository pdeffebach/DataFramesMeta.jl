module DataFramesMeta

using Tables, Reexport

@reexport using DataFrames

# Basics:
export @with, @where, @orderby, @transform, @by, @based_on, @select

include("linqmacro.jl")
include("byrow.jl")


##############################################################################
##
## @with
##
##############################################################################

function addkey!(membernames, nam)
    if !haskey(membernames, nam)
        membernames[nam] = gensym()
    end
    membernames[nam]
end

onearg(e, f) = e.head == :call && length(e.args) == 2 && e.args[1] == f

mapexpr(f, e) = Expr(e.head, map(f, e.args)...)

replace_syms!(x, membernames) = x
replace_syms!(q::QuoteNode, membernames) =
    replace_syms!(Meta.quot(q.value), membernames)
replace_syms!(e::Expr, membernames) =
    if onearg(e, :^)
        e.args[2]
    elseif onearg(e, :_I_)
        @warn "_I_() for escaping variables is deprecated, use cols() instead"
        addkey!(membernames, :($(e.args[2])))
    elseif onearg(e, :cols)
        addkey!(membernames, :($(e.args[2])))
    elseif e.head == :quote
        addkey!(membernames, Meta.quot(e.args[1]) )
    elseif e.head == :.
        replace_dotted!(e, membernames)
    else
        mapexpr(x -> replace_syms!(x, membernames), e)
    end

"""
    @col(kw)

`@col` transforms an expression of the form `z = :x + :y` into it's equivalent in
DataFrames's `source => fun => destination` syntax.

### Details

Parsing follows the same convention as other DataFramesMeta.jl macros, such as `@with`. All
terms in the expression that are `Symbol`s are treated as columns in the data frame, except
`Symbol`s wrapped in `^`. To use a variable representing a column name, wrap the variable
in `cols`.

`@col` constructs an anonymous function `fun` based on the given expression. It then creates
a `source => fun => destination` pair that is suitable for the `select`, `transform`, and
`combine` functions in DataFrames.jl.

### Examples

```julia
julia> @col z = :x + :y
[:x, :y] => (##595 => :z)
```

In the above example, `##595` is an anonymous function equivalent to the following

```julia
(_x, _y) -> _x + _y
```

```julia
julia> df = DataFrame(x = [1, 2], y = [3, 4]);

julia> DataFrames.transform(df, @col z = :x .* :y)
2×3 DataFrame
│ Row │ x     │ y     │ z     │
│     │ Int64 │ Int64 │ Int64 │
├─────┼───────┼───────┼───────┤
│ 1   │ 1     │ 3     │ 3     │
│ 2   │ 2     │ 4     │ 8     │


```

"""
macro col(kw)
    esc(fun_to_vec(kw))
end

# `nolhs` needs to be `true` when we have syntax of the form
# `@based_on(gd, fun(:x, :y))` where `fun` returns a `table` object.
# We don't create the "new name" pair because new names are given
# by the table.
function fun_to_vec(kw::Expr; nolhs = false)
    # nolhs: f(:x) where f returns a Table
    # !nolhs, y = g(:x)
    if kw.head === :(=) || kw.head === :kw || nolhs
        membernames = Dict{Any, Symbol}()
        if nolhs
            # act on f(:x)
            body = replace_syms!(kw, membernames)
        else
            # act on g(:x)
            body = replace_syms!(kw.args[2], membernames)
        end

        if nolhs
            # [:x] => _f
            t = quote
                $(Expr(:vect, keys(membernames)...)) =>
                ($(Expr(:tuple, values(membernames)...)) -> $body)
            end
         else
            if kw.args[1] isa Symbol
                # cols(n) = f(:x) becomes [:x] => _f => n
                output = QuoteNode(kw.args[1])
            elseif onearg(kw.args[1], :cols)
                # y = f(:x) becomes [:x] => _f => :y
                output = kw.args[1].args[2]
            end
            t = quote
                $(Expr(:vect, keys(membernames)...)) =>
                ($(Expr(:tuple, values(membernames)...)) -> $body) =>
                $(output)
            end
        end
        return t
    else
        throw(ArgumentError("Expressions not of the form `y = f(:x)` currently disallowed."))
    end
end

fun_to_vec(kw::QuoteNode) = kw


protect_replace_syms!(e, membernames) = e
function protect_replace_syms!(e::Expr, membernames)
    if e.head == :quote
        e
    else
        replace_syms!(e, membernames)
    end
end

function replace_dotted!(e, membernames)
    x_new = replace_syms!(e.args[1], membernames)
    y_new = protect_replace_syms!(e.args[2], membernames)
    Expr(:., x_new, y_new)
end

getsinglecolumn(df, s::DataFrames.ColumnIndex) = df[!, s]
getsinglecolumn(df, s) = throw(ArgumentError("Only indexing with Symbols, strings and integers " *
    "is currently allowed with cols"))

function with_helper(d, body)
    membernames = Dict{Any, Symbol}()
    funname = gensym()
    body = replace_syms!(body, membernames)
    if isempty(membernames)
        body
    else
        quote
            function $funname($(values(membernames)...))
                $body
            end
            $funname($((:($getsinglecolumn($d, $key)) for key in keys(membernames))...))
        end
    end
end

function with_anonymous(body)
    d = gensym()
    :($d -> $(with_helper(d, body)))
end

"""
    @with(d, expr)

`@with` allows DataFrame columns keys to be referenced as symbols.

### Arguments

* `d` : an AbstractDataFrame type
* `expr` : the expression to evaluate in `d`

### Details

`@with` works by parsing the expression body for all columns indicated
by symbols (e.g. `:colA`). Then, a function is created that wraps the
body and passes the columns as function arguments. This function is
then called. Operations are efficient because:

- A pseudo-anonymous function is defined, so types are stable.
- Columns are passed as references, eliminating DataFrame indexing.

The following

```julia
@with(d, :a .+ :b .+ 1)
```

becomes

```julia
tempfun(a, b) = a .+ b .+ 1
tempfun(d[!, :a], d[!, :b])
```

All of the other DataFramesMeta macros are based on `@with`.

If an expression is wrapped in `^(expr)`, `expr` gets passed through untouched.
If an expression is wrapped in  `cols(expr)`, the column is referenced by the
variable `expr` rather than a symbol.

### Examples

```jldoctest
julia> using DataFramesMeta

julia> y = 3;

julia> df = DataFrame(x = 1:3, y = [2, 1, 2]);

julia> x = [2, 1, 0];

julia> @with(df, :y .+ 1)
3-element Array{Int64,1}:
 3
 2
 3

julia> @with(df, :x + x)
3-element Array{Int64,1}:
 3
 3
 3

julia> @with df begin
            res = 0.0
            for i in 1:length(:x)
                res += :x[i] * :y[i]
            end
            res
        end
10.0

julia> @with(df, df[:x .> 1, ^(:y)]) # The ^ means leave the :y alone
2-element Array{Int64,1}:
 1
 2

julia> colref = :x;

julia> @with(df, :y + cols(colref)) # Equivalent to df[!, :y] + df[!, colref]
 3
 3
 5
```

`@with` creates a function, so scope within `@with` is a local scope.
Variables in the parent can be read. Writing to variables in the parent scope
differs depending on the type of scope of the parent. If the parent scope is a
global scope, then a variable cannot be assigned without using the `global` keyword.
If the parent scope is a local scope (inside a function or let block for example),
the `global` keyword is not needed to assign to that parent scope.

"""
macro with(d, body)
    esc(with_helper(d, body))
end

##############################################################################
##
## @where - select row subsets
##
##############################################################################

where(d::AbstractDataFrame, arg) = d[arg, :]
where(d::AbstractDataFrame, f::Function) = d[f(d), :]
where(g::GroupedDataFrame, f::Function) = g[Bool[f(x) for x in g]]

and(x, y) = :($x .& $y)

function where_helper(d, args...)
    :($where($d, $(with_anonymous(reduce(and, args)))))
end

"""
    @where(d, i...)

Select row subsets in AbstractDataFrames or groups in GroupedDataFrames.

### Arguments

* `d` : an AbstractDataFrame or GroupedDataFrame
* `i...` : expression for selecting rows

Multiple `i` expressions are "and-ed" together.

### Examples

```jldoctest
julia> using DataFramesMeta, DataFrames

julia> df = DataFrame(x = 1:3, y = [2, 1, 2]);

julia> x = [2, 1, 0];

julia> @where(df, :x .> 1)
2×2 DataFrame
│ Row │ x │ y │
├─────┼───┼───┤
│ 1   │ 2 │ 1 │
│ 2   │ 3 │ 2 │

julia> @where(df, :x .> x)
2×2 DataFrame
│ Row │ x │ y │
├─────┼───┼───┤
│ 1   │ 2 │ 1 │
│ 2   │ 3 │ 2 │

julia> @where(df, :x .> x, :y .== 3)
0×2 DataFrame

julia> d = DataFrame(n = 1:20, x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1,
                                    2, 1, 1, 2, 2, 2, 3, 1, 1, 2]);

julia> g = groupby(d, :x);

julia> @where(d, :x .== 3)
5×2 DataFrame
│ Row │ n  │ x │
├─────┼────┼───┤
│ 1   │ 1  │ 3 │
│ 2   │ 2  │ 3 │
│ 3   │ 3  │ 3 │
│ 4   │ 4  │ 3 │
│ 5   │ 17 │ 3 │

julia> @where(g, length(:x) > 5)   # pick out some groups
GroupedDataFrame  2 groups with keys: Symbol[:x]
First Group:
9×2 SubDataFrame{Array{Int64,1}}
│ Row │ n  │ x │
├─────┼────┼───┤
│ 1   │ 5  │ 1 │
│ 2   │ 6  │ 1 │
│ 3   │ 7  │ 1 │
│ 4   │ 9  │ 1 │
│ 5   │ 10 │ 1 │
│ 6   │ 12 │ 1 │
│ 7   │ 13 │ 1 │
│ 8   │ 18 │ 1 │
│ 9   │ 19 │ 1 │
⋮
Last Group:
6×2 SubDataFrame{Array{Int64,1}}
│ Row │ n  │ x │
├─────┼────┼───┤
│ 1   │ 8  │ 2 │
│ 2   │ 11 │ 2 │
│ 3   │ 14 │ 2 │
│ 4   │ 15 │ 2 │
│ 5   │ 16 │ 2 │
│ 6   │ 20 │ 2 │
```
"""
macro where(d, args...)
    esc(where_helper(d, args...))
end


##############################################################################
##
## @orderby
##
##############################################################################

# needed on Julia 1.0 till #1489 in DataFrames is merged
orderby(d::DataFrame, arg::DataFrame) = d[sortperm(arg), :]

function orderby(d::AbstractDataFrame, args...)
    D = typeof(d)(args...)
    d[sortperm(D), :]
end

orderby(d::AbstractDataFrame, f::Function) = d[sortperm(f(d)), :]
orderby(g::GroupedDataFrame, f::Function) = g[sortperm([f(x) for x in g])]

orderbyconstructor(d::AbstractDataFrame) = (x...) -> DataFrame(Any[x...], Symbol.(1:length(x)))
orderbyconstructor(d) = x -> x

function orderby_helper(d, args...)
    _D = gensym()
    quote
        let $_D = $d
            $orderby($_D, $(with_anonymous(:($orderbyconstructor($_D)($(args...))))))
        end
    end
end

"""
    @orderby(d, i...)

Sort by criteria. Normally used to sort groups in GroupedDataFrames.

### Arguments

* `d` : an AbstractDataFrame or GroupedDataFrame
* `i...` : expression for sorting

### Examples

```jldoctest
julia> using DataFrames, DataFramesMeta, Statistics

julia> d = DataFrame(n = 1:20, x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1,
                                    2, 1, 1, 2, 2, 2, 3, 1, 1, 2]);

julia> g = groupby(d, :x);

julia> @orderby(g, mean(:n))
GroupedDataFrame  3 groups with keys: Symbol[:x]
First Group:
5×2 SubDataFrame{Array{Int64,1}}
│ Row │ n  │ x │
├─────┼────┼───┤
│ 1   │ 1  │ 3 │
│ 2   │ 2  │ 3 │
│ 3   │ 3  │ 3 │
│ 4   │ 4  │ 3 │
│ 5   │ 17 │ 3 │
⋮
Last Group:
6×2 SubDataFrame{Array{Int64,1}}
│ Row │ n  │ x │
├─────┼────┼───┤
│ 1   │ 8  │ 2 │
│ 2   │ 11 │ 2 │
│ 3   │ 14 │ 2 │
│ 4   │ 15 │ 2 │
│ 5   │ 16 │ 2 │
│ 6   │ 20 │ 2 │
```

"""
macro orderby(d, args...)
    # I don't esc just the input because I want _DF to be visible to the user
    esc(orderby_helper(d, args...))
end

##############################################################################
##
## transform & @transform
##
##############################################################################


function transform_helper(x, args...)

    t = (fun_to_vec(arg) for arg in args)

    quote
        $DataFrames.transform($x, $(t...))
    end
end

"""
    @transform(d, i...)

Add additional columns or keys based on keyword arguments.

### Arguments

* `d` : an `AbstractDataFrame`, or `GroupedDataFrame`
* `i...` : keyword arguments defining new columns or keys

### Returns

* `::AbstractDataFrame` or `::GroupedDataFrame`

### Examples

```jldoctest
julia> using DataFramesMeta, DataFrames

julia> df = DataFrame(A = 1:3, B = [2, 1, 2]);

julia> @transform(df, a = 2 * :A, x = :A .+ :B)
3×4 DataFrame
│ Row │ A │ B │ a │ x │
├─────┼───┼───┼───┼───┤
│ 1   │ 1 │ 2 │ 2 │ 3 │
│ 2   │ 2 │ 1 │ 4 │ 3 │
│ 3   │ 3 │ 2 │ 6 │ 5 │
```

"""
macro transform(x, args...)
    esc(transform_helper(x, args...))
end


##############################################################################
##
## @based_on - summarize a grouping operation
##
##############################################################################

function based_on_helper(x, args...)
    # Only allow one argument when returning a Table object
    if length(args) == 1 &&
        !(first(args) isa QuoteNode) &&
        !(first(args).head == :(=) || first(args).head == :kw)

        t = fun_to_vec(first(args); nolhs = true)
        quote
            $DataFrames.combine($t, $x)
        end
    else
        t = (fun_to_vec(arg) for arg in args)
        quote
            $DataFrames.combine($x, $(t...))
        end
    end
end

"""
    @based_on(g, i...)

Summarize a grouping operation

### Arguments

* `g` : a GroupedDataFrame
* `i...` : keyword arguments defining new columns

### Examples

```jldoctest
julia> using DataFramesMeta, DataFrames

julia> d = DataFrame(
            n = 1:20,
            x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1, 2, 1, 1, 2, 2, 2, 3, 1, 1, 2]);

julia> g = groupby(d, :x);

julia> @based_on(g, nsum = sum(:n))
3×2 DataFrame
│ Row │ x │ nsum │
├─────┼───┼──────┤
│ 1   │ 1 │ 99   │
│ 2   │ 2 │ 84   │
│ 3   │ 3 │ 27   │

julia> @based_on(g, x2 = 2 * :x, nsum = sum(:n))
20×3 DataFrame
│ Row │ x │ x2 │ nsum │
├─────┼───┼────┼──────┤
│ 1   │ 1 │ 2  │ 99   │
│ 2   │ 1 │ 2  │ 99   │
│ 3   │ 1 │ 2  │ 99   │
│ 4   │ 1 │ 2  │ 99   │
│ 5   │ 1 │ 2  │ 99   │
│ 6   │ 1 │ 2  │ 99   │
│ 7   │ 1 │ 2  │ 99   │
│ 8   │ 1 │ 2  │ 99   │
⋮
│ 12  │ 2 │ 4  │ 84   │
│ 13  │ 2 │ 4  │ 84   │
│ 14  │ 2 │ 4  │ 84   │
│ 15  │ 2 │ 4  │ 84   │
│ 16  │ 3 │ 6  │ 27   │
│ 17  │ 3 │ 6  │ 27   │
│ 18  │ 3 │ 6  │ 27   │
│ 19  │ 3 │ 6  │ 27   │
│ 20  │ 3 │ 6  │ 27   │
```
"""
macro based_on(x, args...)
    esc(based_on_helper(x, args...))
end


##############################################################################
##
## @by - grouping
##
##############################################################################

function by_helper(x, what, args...)
    # Only allow one argument when returning a Table object
    if length(args) == 1 &&
        !(first(args) isa QuoteNode) &&
        !(first(args).head == :(=) || first(args).head == :kw)

        t = fun_to_vec(first(args); nolhs = true)
        quote
            $DataFrames.combine($t, $groupby($x, $what))
        end
    else
        t = (fun_to_vec(arg) for arg in args)
        quote
            $DataFrames.combine($groupby($x, $what), $(t...))
        end
    end
end

"""
    @by(d::AbstractDataFrame, cols, e...)

Split-apply-combine in one step.

### Arguments

* `d` : an AbstractDataFrame
* `cols` : a column indicator (Symbol, Int, Vector{Symbol}, etc.)
* `e` :  keyword arguments specifying new columns in terms of column groupings

### Returns

* `::DataFrame`

### Examples

```jldoctest
julia> using DataFrames, DataFramesMeta, Statistics

julia> df = DataFrame(
            a = repeat(1:4, outer = 2),
            b = repeat(2:-1:1, outer = 4),
            c = randn(8));

julia> @by(df, :a, d = sum(:c))
4×2 DataFrame
│ Row │ a │ d        │
├─────┼───┼──────────┤
│ 1   │ 1 │ 1.27638  │
│ 2   │ 2 │ 1.00951  │
│ 3   │ 3 │ 1.48328  │
│ 4   │ 4 │ -2.42621 │

julia> @by(df, :a, d = 2 * :c)
8×2 DataFrame
│ Row │ a │ d         │
├─────┼───┼───────────┤
│ 1   │ 1 │ 1.22982   │
│ 2   │ 1 │ 1.32294   │
│ 3   │ 2 │ 1.93664   │
│ 4   │ 2 │ 0.0823819 │
│ 5   │ 3 │ -0.670512 │
│ 6   │ 3 │ 3.63708   │
│ 7   │ 4 │ -3.06436  │
│ 8   │ 4 │ -1.78806  │

julia> @by(df, :a, c_sum = sum(:c), c_mean = mean(:c))
4×3 DataFrame
│ Row │ a │ c_sum    │ c_mean   │
├─────┼───┼──────────┼──────────┤
│ 1   │ 1 │ 1.27638  │ 0.63819  │
│ 2   │ 2 │ 1.00951  │ 0.504755 │
│ 3   │ 3 │ 1.48328  │ 0.741642 │
│ 4   │ 4 │ -2.42621 │ -1.2131  │

julia> @by(df, :a, c = :c, c_mean = mean(:c))
8×3 DataFrame
│ Row │ a │ c         │ c_mean   │
├─────┼───┼───────────┼──────────┤
│ 1   │ 1 │ 0.61491   │ 0.63819  │
│ 2   │ 1 │ 0.66147   │ 0.63819  │
│ 3   │ 2 │ 0.968319  │ 0.504755 │
│ 4   │ 2 │ 0.041191  │ 0.504755 │
│ 5   │ 3 │ -0.335256 │ 0.741642 │
│ 6   │ 3 │ 1.81854   │ 0.741642 │
│ 7   │ 4 │ -1.53218  │ -1.2131  │
│ 8   │ 4 │ -0.894029 │ -1.2131  │
```
"""
macro by(x, what, args...)
    esc(by_helper(x, what, args...))
end


##############################################################################
##
## @select - select and transform columns
##
##############################################################################

function select_helper(x, args...)
    t = (fun_to_vec(arg) for arg in args)

    quote
        $DataFrames.select($x, $(t...))
    end
end

"""
    @select(d, e...)

Select and transform columns.

### Arguments

* `d` : an AbstractDataFrame
* `e` :  keyword arguments specifying new columns in terms of existing columns
  or symbols to specify existing columns

### Returns

* `::AbstractDataFrame`

### Examples

```jldoctest
julia> using DataFrames, DataFramesMeta

julia> df = DataFrame(a = repeat(1:4, outer = 2), b = repeat(2:-1:1, outer = 4), c = randn(8))
8×3 DataFrame
│ Row │ a │ b │ c         │
├─────┼───┼───┼───────────┤
│ 1   │ 1 │ 2 │ -0.354685 │
│ 2   │ 2 │ 1 │ 0.287631  │
│ 3   │ 3 │ 2 │ -0.918007 │
│ 4   │ 4 │ 1 │ -0.352519 │
│ 5   │ 1 │ 2 │ 0.743501  │
│ 6   │ 2 │ 1 │ -1.27415  │
│ 7   │ 3 │ 2 │ 0.258456  │
│ 8   │ 4 │ 1 │ -0.460486 │

julia> @select(df, :c, :a)
8×2 DataFrame
│ Row │ c         │ a │
├─────┼───────────┼───┤
│ 1   │ -0.354685 │ 1 │
│ 2   │ 0.287631  │ 2 │
│ 3   │ -0.918007 │ 3 │
│ 4   │ -0.352519 │ 4 │
│ 5   │ 0.743501  │ 1 │
│ 6   │ -1.27415  │ 2 │
│ 7   │ 0.258456  │ 3 │
│ 8   │ -0.460486 │ 4 │

julia> @select(df, :c, x = :b + :c)
8×2 DataFrame
│ Row │ c         │ x         │
├─────┼───────────┼───────────┤
│ 1   │ -0.354685 │ 1.64531   │
│ 2   │ 0.287631  │ 1.28763   │
│ 3   │ -0.918007 │ 1.08199   │
│ 4   │ -0.352519 │ 0.647481  │
│ 5   │ 0.743501  │ 2.7435    │
│ 6   │ -1.27415  │ -0.274145 │
│ 7   │ 0.258456  │ 2.25846   │
│ 8   │ -0.460486 │ 0.539514  │
```
"""
macro select(x, args...)
    esc(select_helper(x, args...))
end

end # module
