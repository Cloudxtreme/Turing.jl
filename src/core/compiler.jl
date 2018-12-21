using Base.Meta: parse

#################
# Overload of ~ #
#################

struct CallableModel{pvars, dvars, F, TD}
    f::F
    data::TD
end
function CallableModel{pvars, dvars}(f::F, data::TD) where {pvars, dvars, F, TD}
    return CallableModel{pvars, dvars, F, TD}(f, data)
end
pvars(m::CallableModel{params}) where {params} = Tuple(params.types)
function dvars(m::CallableModel{params, data}) where {params, data}
    return Tuple(data.types)
end
@generated function inpvars(::Val{sym}, ::CallableModel{params}) where {sym, params}
    if sym in params.types
        return :(true)
    else
        return :(false)
    end
end
@generated function indvars(::Val{sym}, ::CallableModel{params, data}) where {sym, params, data}
    if sym in data.types
        return :(true)
    else
        return :(false)
    end
end

(m::CallableModel)(args...; kwargs...) = m.f(args..., m; kwargs...)

# TODO: Replace this macro, see issue #514
"""
Usage: @VarName x[1,2][1+5][45][3]
  return: (:x,[1,2],6,45,3)
"""
macro VarName(expr::Union{Expr, Symbol})
    ex = deepcopy(expr)
    isa(ex, Symbol) && return var_tuple(ex)
    (ex.head == :ref) || throw("VarName: Mis-formed variable name $(expr)!")
    inds = :(())
    while ex.head == :ref
        if length(ex.args) >= 2
            pushfirst!(inds.args, Expr(:vect, ex.args[2:end]...))
            end
        ex = ex.args[1]
        isa(ex, Symbol) && return var_tuple(ex, inds)
    end
    throw("VarName: Mis-formed variable name $(expr)!")
end
function var_tuple(sym::Symbol, inds::Expr=:(()))
    return esc(:($(QuoteNode(sym)), $inds, $(QuoteNode(gensym()))))
end


wrong_dist_errormsg(l) = "Right-hand side of a ~ must be subtype of Distribution or a vector of Distributions on line $(l)."

"""
    generate_observe(observation, distribution)

Generate an observe expression for observation `observation` drawn from 
a distribution or a vector of distributions (`distribution`).
"""
function generate_observe(observation, dist)
    return quote
            isdist = if isa($dist, AbstractVector)
                # Check if the right-hand side is a vector of distributions.
                all(d -> isa(d, Distribution), $dist)
            else
                # Check if the right-hand side is a distribution.
                isa($dist, Distribution)
            end
            @assert isdist @error($(wrong_dist_errormsg(@__LINE__)))
            vi.logp += Turing.observe(sampler, $dist, $observation, vi)
        end
end

"""
    generate_assume(variable, distribution, model_info)

Generate an assume expression for parameters `variable` drawn from 
a distribution or a vector of distributions (`distribution`).

"""
function generate_assume(var::Union{Symbol, Expr}, dist, model_info)
    if var isa Symbol
        varname_expr = quote
            sym, idcs, csym = @VarName $var
            csym = Symbol($(model_info[:name]), csym)
            syms = Symbol[csym, $(QuoteNode(var))]
            varname = Turing.VarName(vi, syms, "")
        end
    else
        varname_expr = quote
            sym, idcs, csym = @VarName $var
            csym_str = string($(model_info[:name]))*string(csym)
            indexing = mapfoldl(string, *, idcs, init = "")
            varname = Turing.VarName(vi, Symbol(csym_str), sym, indexing)
        end
    end
    return quote
        $varname_expr
        isdist = if isa($dist, AbstractVector)
            # Check if the right-hand side is a vector of distributions.
            all(d -> isa(d, Distribution), $dist)
        else
            # Check if the right-hand side is a distribution.
            isa($dist, Distribution)
        end
        @assert isdist @error($(wrong_dist_errormsg(@__LINE__)))

        ($var, _lp) = if isa($dist, AbstractVector)
            Turing.assume(sampler, $dist, varname, $var, vi)
        else
            Turing.assume(sampler, $dist, varname, vi)
        end
        vi.logp += _lp
    end
end

function tilde(left, right, model_info)
    return generate_observe(left, right)
end

function tilde(left::Union{Symbol, Expr}, right, model_info)
    if left isa Symbol
        vsym = left
    else
        vsym = getvsym(left)
    end
    @assert isa(vsym, Symbol)
    return _tilde(vsym, left, right, model_info)
end

function _tilde(vsym, left, dist, model_info)
    if vsym in model_info[:args]
        if !(vsym in model_info[:dvars])
            @debug " Observe - `$(vsym)` is an observation"
            push!(model_info[:dvars], vsym)
        end

        return quote 
            if Turing.indvars($(Val(vsym)), model)
                $(generate_observe(left, dist))
            else
                $(generate_assume(left, dist, model_info))
            end
        end
    else
        # Assume it is a parameter.
        if !(vsym in model_info[:pvars])
            msg = " Assume - `$(vsym)` is a parameter"
            if isdefined(Main, vsym)
                msg  *= " (ignoring `$(vsym)` found in global scope)"
            end

            @debug msg
            push!(model_info[:pvars], vsym)
        end

        return generate_assume(left, dist, model_info)
    end
end

#################
# Main Compiler #
#################

"""
    @model(name, fbody)

Macro to specify a probabilistic model.

Example:

```julia
@model Gaussian(x) = begin
    s ~ InverseGamma(2,3)
    m ~ Normal(0,sqrt.(s))
    for i in 1:length(x)
        x[i] ~ Normal(m, sqrt.(s))
    end
    return (s, m)
end
```

Compiler design: `sample(fname(x,y), sampler)`.
```julia
fname(x=nothing,y=nothing) = begin
    ex = quote
        # Pour in kwargs for those args where value != nothing.
        fname_model(vi::VarInfo, sampler::Sampler; x = x, y = y) = begin
            vi.logp = zero(Real)
          
            # Pour in model definition.
            x ~ Normal(0,1)
            y ~ Normal(x, 1)
            return x, y
        end
    end
    return Main.eval(ex)
end
```
"""
macro model(fexpr)
    _model(fexpr)
end
function _model(fexpr)
    # Extract model name (:name), arguments (:args), (:kwargs) and definition (:body)
    modeldef = MacroTools.splitdef(fexpr)
    # Function body of the model is empty
    warn_empty(modeldef[:body])
    # Construct model_info dictionary
    
    args = [(arg isa Symbol) ? arg : arg.args[1] for arg in modeldef[:args]]
    model_info = Dict(
        :name => modeldef[:name],
        :closure_name => gensym(),
        :args => args,
        :kwargs => modeldef[:kwargs],
        :dvars => Symbol[],
        :pvars => Symbol[]
    )
    # Unwrap ~ expressions and extract dvars and pvars into `model_info`
    fexpr = translate(fexpr, model_info)

    fargs = modeldef[:args]
    fargs_default_values = Dict()
    for i in 1:length(fargs)
        if isa(fargs[i], Symbol)
            fargs_default_values[fargs[i]] = :nothing
            fargs[i] = Expr(:kw, fargs[i], :nothing)
        elseif isa(fargs[i], Expr) && fargs[i].head == :kw
            fargs_default_values[fargs[i].args[1]] = fargs[i].args[2]
            fargs[i] = Expr(:kw, fargs[i].args[1], :nothing)
        else
            throw("Unsupported argument type $(fargs[i]).")
        end
    end
    
    # Construct user-facing function
    outer_function_name = model_info[:name]
    pvars = model_info[:pvars]
    dvars = model_info[:dvars]

    closure_name = model_info[:closure_name]
    # Updated body after expanding ~ expressions
    closure_main_body = MacroTools.splitdef(fexpr)[:body]

    if length(dvars) == 0
        dvars_nt = :(NamedTuple())
    else
        dvars_nt = :($([:($var = $var) for var in dvars]...),)
    end
    unwrap_data_expr = Expr(:block)
    for var in dvars
        push!(unwrap_data_expr.args, quote
            local $var
            if isdefined(model.data, $(QuoteNode(var)))
                $var = model.data.$var
            else
                $var = $(fargs_default_values[var])
            end
        end)
    end
    return esc(quote
        function $(outer_function_name)($(fargs...))
            pvars, dvars = Turing.get_vars($(Tuple{pvars...}), $dvars_nt)
            data = Turing.get_data(dvars, $dvars_nt)
            $closure_name(sampler::Turing.AnySampler, model) = $closure_name(model)
            $closure_name(model) = $closure_name(Turing.VarInfo(), Turing.SampleFromPrior(), model)
            $closure_name(vi::Turing.VarInfo, model) = $closure_name(vi, Turing.SampleFromPrior(), model)
            function $closure_name(vi::Turing.VarInfo, sampler::Turing.AnySampler, model)
                $unwrap_data_expr
                vi.logp = zero(Real)
                $closure_main_body
            end
            model = Turing.CallableModel{pvars, dvars}($closure_name, data)
            return model
        end
    end)
end

@generated function get_vars(pvars::Type{Tpvars}, dvars_nt::NamedTuple) where {Tpvars <: Tuple}
    pvar_syms = [Tpvars.types...]
    dvar_syms = [dvars_nt.names...]
    dvar_types = [dvars_nt.types...]
    append!(pvar_syms, [dvar_syms[i] for i in 1:length(dvar_syms) if dvar_types[i] == Nothing])
    setdiff!(dvar_syms, pvar_syms)    
    pvars = Tuple{pvar_syms...}
    dvars = Tuple{dvar_syms...}
    return :($pvars, $dvars)
end

@generated function get_data(::Type{Tdvars}, nt) where Tdvars
    dvars = Tdvars.types
    args = []
    for var in dvars
        push!(args, :($var = nt.$var))
    end
    if length(args) == 0
        return :(NamedTuple())
    else
        return :($(args...),)
    end
end

function warn_empty(body)
    if all(l -> isa(l, LineNumberNode), body.args)
        @warn("Model definition seems empty, still continue.")
    end
    return 
end

####################
# Helper functions #
####################

getvsym(s::Symbol) = s
function getvsym(expr::Expr)
    @assert expr.head == :ref "expr needs to be an indexing expression, e.g. :(x[1])"
    return getvsym(expr.args[1])
end

translate!(ex::Any, model_info) = ex
function translate!(ex::Expr, model_info)
    ex = MacroTools.postwalk(x -> @capture(x, L_ ~ R_) ? tilde(L, R, model_info) : x, ex)
    return ex
end
translate(ex::Expr, model_info) = translate!(deepcopy(ex), model_info)
