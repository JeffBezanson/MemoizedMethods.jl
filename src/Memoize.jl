module Memoize
using MacroTools: isexpr, combinearg, combinedef, namify, splitarg, splitdef, @capture
export @memoize, memories, memory

# I would call which($sig) but it's only on 1.6 I think
function _which(tt, world = typemax(UInt))
    meth = ccall(:jl_gf_invoke_lookup, Any, (Any, UInt), tt, world)
    if meth !== nothing
        if meth isa Method
            return meth::Method
        else
            meth = meth.func
            return meth::Method
        end
    end
end

const _brain = Dict()
brain() = _brain

"""
    @memoize [cache] declaration
    
    Transform any method declaration `declaration` (except for inner constructors) so that calls to the original method are cached by their arguments. When an argument is unnamed, its type is treated as an argument instead.
    
    `cache` should be an expression which evaluates to a dictionary-like type that supports `get!` and `empty!`, and may depend on the local variables `__Key__` and `__Value__`, which evaluate to syntactically-determined bounds on the required key and value types the cache must support.

    If the given cache contains values, it is assumed that they will agree with the values the method returns. Specializing a method will not empty the cache, but overwriting a method will. The caches corresponding to methods can be determined with `memory` or `memories.`
"""
macro memoize(args...)
    if length(args) == 1
        cache_constructor = :(IdDict{__Key__}{__Val__}())
        ex = args[1]
    elseif length(args) == 2
        (cache_constructor, ex) = args
    else
        error("Memoize accepts at most two arguments")
    end

    def = try
        splitdef(ex)
    catch
        error("@memoize must be applied to a method definition")
    end

    # Set up arguments for memo key
    key_args = []
    key_arg_types = []

    # Ensure that all args have names that can be passed to the inner function
    function tag_arg(arg)
        arg_name, arg_type, slurp, default = splitarg(arg)
        if arg_name === nothing
            arg_name = gensym()
            push!(key_args, arg_type)
            push!(key_arg_types, :(DataType))
        elseif namify(arg_type) === :Vararg
            push!(key_args, arg_name)
            push!(key_arg_types, :(Tuple{$arg_type}))
        else
            push!(key_args, arg_name)
            push!(key_arg_types, arg_type)
        end
        return combinearg(arg_name, arg_type, slurp, default)
    end
    args = def[:args] = map(tag_arg, def[:args])
    kwargs = def[:kwargs] = map(tag_arg, def[:kwargs])

    # Get argument types for function signature
    arg_sigs = Vector{Any}(map(def[:args]) do arg
        arg_name, arg_type, slurp, default = splitarg(arg)
        if slurp
            return :(Vararg{$arg_type})
        else
            return arg_type
        end
    end)

    # Set up identity arguments to pass to unmemoized function
    pass_args = Vector{Any}(map(args) do arg
        arg_name, arg_type, slurp, default = splitarg(arg)
        if slurp || namify(arg_type) === :Vararg
            Expr(:..., arg_name)
        else
            arg_name
        end
    end)
    pass_arg_types = copy(arg_sigs)
    pass_kwargs = Vector{Any}(map(kwargs) do kwarg
        kwarg_name, kwarg_type, slurp, default = splitarg(kwarg)
        if slurp
            Expr(:..., kwarg_name)
        else
            Expr(:kw, kwarg_name, kwarg_name)
        end
    end)

    @gensym inner
    inner_def = deepcopy(def)
    inner_def[:name] = inner
    pop!(inner_def, :params, nothing)

    @gensym result

    println(key_arg_types)

    # If this is a method of a callable type or object, the definition returns nothing.
    # Thus, we must construct the type of the method on our own.
    # We also need to pass the object to the inner function
    if haskey(def, :name)
        if haskey(def, :params)
            # Callable type
            typ = :($(def[:name]){$(def[:params]...)})
            sig = :(Tuple{Type{$typ}, $(arg_sigs...)} where {$(def[:whereparams]...)})
            pushfirst!(inner_def[:args], :(::Type{$typ}))
            pushfirst!(pass_args, typ)
            pushfirst!(pass_arg_types, :(Type{$typ}))
            pushfirst!(key_args, typ)
            pushfirst!(key_arg_types, :(DataType))
        elseif @capture(def[:name], obj_::obj_type_ | ::obj_type_)
            # Callable object
            obj_type === nothing && (obj_type = Any)
            if obj === nothing
                obj = gensym()
                pushfirst!(key_args, obj_type)
                pushfirst!(key_arg_types, :(DataType))
            else
                pushfirst!(key_args, obj)
                pushfirst!(key_arg_types, obj_type)
            end
            def[:name] = :($obj::$obj_type)
            sig = :(Tuple{$obj_type, $(arg_sigs...)} where {$(def[:whereparams]...)})
            pushfirst!(inner_def[:args], :($obj::$obj_type))
            pushfirst!(pass_args, obj)
            pushfirst!(pass_arg_types, obj_type)
        else
            # Normal call
            sig = :(Tuple{typeof($(def[:name])), $(arg_sigs...)} where {$(def[:whereparams]...)})
        end
    else
        # Anonymous function
        sig = :(Tuple{typeof($result), $(arg_sigs...)} where {$(def[:whereparams]...)})
    end

    @gensym cache

    def[:body] = quote
        $(combinedef(inner_def))
        get!($cache, ($(key_args...),)) do
            $inner($(pass_args...); $(pass_kwargs...))
        end
    end

    # A return type declaration of Any is a No-op because everything is <: Any
    return_type = get(def, :rtype, Any)

    if length(kwargs) == 0
        def[:body] = quote
            $(def[:body])::Core.Compiler.return_type($inner, typeof(($(pass_args...),)))
        end
    end

    @gensym world
    @gensym old_meth
    @gensym meth

    res = esc(quote
        # The `local` qualifier will make this performant even in the global scope.
        local $cache = begin
            local __Key__ = (Tuple{$(key_arg_types...)} where {$(def[:whereparams]...)})
            local __Val__ = ($return_type where {$(def[:whereparams]...)})
            $cache_constructor
        end

        local $world = Base.get_world_counter()

        local $result = Base.@__doc__($(combinedef(def)))
        
        # If overwriting a method, empty the old cache.
        local $old_meth = $_which($sig, $world)
        if $old_meth !== nothing && $old_meth.sig == $sig
            empty!(pop!($brain(), $old_meth, []))
        end

        # Store the cache so that it can be emptied later
        local $meth = $_which($sig)
        @assert $meth !== nothing
        $brain()[$meth] = $cache

        $result
    end)
    return res
end

"""
    memories(f, [types], [module])
    
    Return an array of memoized method caches for the function f.
    
    This function takes the same arguments as the method methods.
"""
memories(f, args...) = _memories(methods(f, args...))

function _memories(ms::Base.MethodList)
    memories = []
    for m in ms
        memory = get(brain(), m, nothing)
        if memory !== nothing
            push!(memories, memory)
        end
    end
    return memories
end

"""
    memory(m)
    
    Return the memoized cache for the method m, or nothing if no such method exists
"""
function memory(m::Method)
    return get(brain(), m, nothing)
end

end