
export @byrow!
export @byrow

##############################################################################
##
## @byrow
##
##############################################################################

# Recursive function that traverses the syntax tree of e, replaces instances of
# ":(:(x))" with ":x[row]".
function byrow_replace(e::Expr)
    # Traverse the syntax tree of e
    if onearg(e, :cols)
        # cols(:x) becomes cols(:x)[row]
        return Expr(:ref, Expr(:call, :cols, e.args[2]), :row)
    end

    if e.head == :.
        if e.args[1] isa QuoteNode
            e.args[1] = Expr(:ref, e.args[1], :row)
            return e
        else
            return e
        end
    end

    Expr(e.head, (isempty(e.args) ? e.args : map(byrow_replace, e.args))...)
end

byrow_replace(e::QuoteNode) = Expr(:ref, e, :row)

# Set the base case for helper, i.e. for when expand hits an object of type
# other than Expr (generally a Symbol or a literal).
byrow_replace(x) = x

function byrow_find_newcols(e::Expr, newcol_decl)
    if e.head == :macrocall && e.args[1] == Symbol("@newcol")
        ea = e.args[3]
        # expression to assign a new column to df
        return (nothing, Any[Expr(:(=), ea.args[1], Expr(:call, ea.args[2], :undef, :_N))])
    else
        if isempty(e.args)
            return (e.args, Any[])
        end
        newargs = Any[]
        for ea in e.args
            (nea, newcol) = byrow_find_newcols(ea, newcol_decl)
            nea != nothing && push!(newargs, nea)
            nea == nothing && length(newcol) > 0 && append!(newcol_decl, newcol)
        end
        return (Expr(e.head, newargs...), newcol_decl)
    end
end

byrow_find_newcols(x, newcol_decl) = (x, Any[])

function byrow_helper(df, body, deprecation_warning)
    # @deprecate cannot be used because byrow is a macro, and the @warn should not be in
    # byrow itself because then it will be displayed when the macro is evaluated.
    deprecation_warning && @warn "`@byrow!` is deprecated, use `@byrow` instead."
    e_body, e_newcols = byrow_find_newcols(body, Any[])
    _df = gensym()
    quote
        let $_df = $df
            local _N = nrow($_df)
            local _DF = @transform($_df, $(e_newcols...))
            $(with_helper(:_DF, :(for row = 1:_N
                $(byrow_replace(e_body))
            end)))
            _DF
        end
    end
end

"""
    @byrow!(d, expr)

Deprecated version of `@byrow`, see: [`@byrow`](@ref)

Acts the exact same way. It does not change the input argument `d` in-place.
"""
macro byrow!(df, body)
    esc(byrow_helper(df, body, true))
end

"""
    @byrow(d, expr)

Act on a DataFrame row-by-row.

Includes support for control flow and `begin end` blocks. Since the
"environment" induced by `@byrow df` is implicitly a single row of `df`,
use regular operators and comparisons instead of their elementwise counterparts
as in `@with`. Note that the scope within `@byrow` is a hard scope.

`byrow` also supports special syntax for allocating new columns. The syntax
`@newcol x::Array{Int}` allocates a new column `:x` with an `Array` container
with eltype `Int`.This feature makes it easier to use `byrow` for data
transformations. `_N` is introduced to represent the length of the dataframe,
`_D` represents the `dataframe` including added columns, and `row` represents
the index of the current row.

Changes to the rows do not affect `d` but instead a freshly allocated data frame is returned
by `@byrow`. Also note that the returned data frame does not share columns
with `d`.

Like with `@transform`, `@byrow` supports the use of `cols` to work with column names
stored as variables. Using `cols` with a multi-column selector, such as a `Vector` of
`Symbol`s, is currently unsupported.

### Arguments

* `d` : an `AbstractDataFrame`
* `expr` : expression operated on row by row

### Returns

The modified `AbstractDataFrame`.

### Examples

```julia
julia> using DataFrames, DataFramesMeta

julia> df = DataFrame(A = 1:3, B = [2, 1, 2]);

julia> let x = 0
            @byrow df begin
                if :A + :B == 3
                    x += 1
                end
            end  #  This doesn't work without the let
            x
        end
2

julia> @byrow df begin
            if :A > :B
                :A = 0
            end
        end
3×2 DataFrame
│ Row │ A │ B │
├─────┼───┼───┤
│ 1   │ 1 │ 2 │
│ 2   │ 0 │ 1 │
│ 3   │ 0 │ 2 │

julia> df2 = @byrow df begin
           @newcol colX::Array{Float64}
           :colX = :B == 2 ? pi * :A : :B
       end
3×3 DataFrame
│ Row │ A │ B │ colX    │
├─────┼───┼───┼─────────┤
│ 1   │ 1 │ 2 │ 3.14159 │
│ 2   │ 0 │ 1 │ 1.0     │
│ 3   │ 0 │ 2 │ 0.0     │

julia> varA = :A; varB = :B;

julia> df2 = @byrow df begin
           @newcol colX::Array{Float64}
           :colX = cols(varB) == 2 ? pi * cols(varA) : cols(varB)
       end
3×3 DataFrame
│ Row │ A │ B │ colX    │
├─────┼───┼───┼─────────┤
│ 1   │ 1 │ 2 │ 3.14159 │
│ 2   │ 0 │ 1 │ 1.0     │
│ 3   │ 0 │ 2 │ 0.0     │
```

"""
macro byrow(df, body)
    esc(byrow_helper(df, body, false))
end
