module Tools

export AbstractToolDef,
    ToolDef,
    ToolRegistry,
    ToolNotFoundError,
    ToolValidationError,
    ToolExecutionError,
    register_tool!,
    unregister_tool!,
    get_tool,
    has_tool,
    tool_names,
    tools_schema,
    dispatch_tool,
    @tool

"""
    AbstractToolDef

Abstract supertype for tool definitions. Subtypes must have `name`, `parameters`,
`description`, `execute`, `return_direct`, `max_output_chars`, and `strict` fields.
"""
abstract type AbstractToolDef end

"""
    ToolDef(; name, parameters, execute, description=nothing, return_direct=false, max_output_chars=0, strict=nothing)

Defines a callable tool with JSON-schema parameters and execution behavior.
`execute` receives a `Dict{String,Any}` of validated arguments.
"""
struct ToolDef <: AbstractToolDef
    name::String
    parameters::Dict{String,Any}
    description::Union{Nothing,String}
    execute::Function
    return_direct::Bool
    max_output_chars::Int
    strict::Union{Nothing,Bool}
end

function ToolDef(;
    name::AbstractString,
    parameters::Dict{String,Any},
    execute::Function,
    description::Union{Nothing,AbstractString} = nothing,
    return_direct::Bool = false,
    max_output_chars::Int = 0,
    strict::Union{Nothing,Bool} = nothing,
)
    isempty(strip(String(name))) && throw(ArgumentError("tool name must not be empty"))
    max_output_chars < 0 && throw(ArgumentError("max_output_chars must be >= 0"))
    get(parameters, "type", "object") == "object" ||
        throw(ArgumentError("tool parameters must be an object schema"))

    return ToolDef(
        String(name),
        copy(parameters),
        description === nothing ? nothing : String(description),
        execute,
        return_direct,
        max_output_chars,
        strict,
    )
end

"""
    ToolRegistry()
    ToolRegistry(tools::Vector{<:ToolDef})

Thread-safe registry of named tools. All read and write operations are protected
by a `ReentrantLock`. Tool execution (via `dispatch_tool`) releases the lock
before calling the tool's `execute` function.
"""
mutable struct ToolRegistry
    tools::Dict{String,ToolDef}
    lock::ReentrantLock
end

ToolRegistry() = ToolRegistry(Dict{String,ToolDef}(), ReentrantLock())

function ToolRegistry(tools::Vector{<:ToolDef})
    registry = ToolRegistry()
    for tool in tools
        register_tool!(registry, tool)
    end
    return registry
end

"""
    ToolNotFoundError <: Exception

Thrown by `dispatch_tool` when the requested tool name is not in the registry.
Includes the list of available tool names for diagnostics.
"""
struct ToolNotFoundError <: Exception
    tool_name::String
    available::Vector{String}
end

function Base.showerror(io::IO, err::ToolNotFoundError)
    available = isempty(err.available) ? "(none)" : join(sort(err.available), ", ")
    print(io, "Tool not found: ", err.tool_name, ". Available: ", available)
end

"""
    ToolValidationError <: Exception

Thrown by `dispatch_tool` when tool arguments fail schema validation.
Contains a list of human-readable error strings.
"""
struct ToolValidationError <: Exception
    tool_name::String
    errors::Vector{String}
end

function Base.showerror(io::IO, err::ToolValidationError)
    print(io, "Invalid arguments for tool ", err.tool_name, ": ", join(err.errors, "; "))
end

"""
    ToolExecutionError <: Exception

Thrown by `dispatch_tool` when a tool's `execute` function raises an error.
Wraps the original exception and captures its backtrace for diagnostics.
"""
struct ToolExecutionError <: Exception
    tool_name::String
    error::Any
    backtrace::Union{Nothing,Vector}
end

ToolExecutionError(tool_name::String, error) = ToolExecutionError(tool_name, error, nothing)

function Base.showerror(io::IO, err::ToolExecutionError)
    print(io, "Tool execution failed (", err.tool_name, "): ", sprint(showerror, err.error))
    if err.backtrace !== nothing
        println(io)
        Base.show_backtrace(io, err.backtrace)
    end
end

"""
    register_tool!(registry, tool; replace=false) -> ToolRegistry

Add a tool to the registry. Throws `ArgumentError` if a tool with the same name
already exists and `replace` is false.
"""
function register_tool!(registry::ToolRegistry, tool::ToolDef; replace::Bool = false)
    lock(registry.lock) do
        if haskey(registry.tools, tool.name) && !replace
            throw(ArgumentError("tool already registered: $(tool.name)"))
        end
        registry.tools[tool.name] = tool
    end
    return registry
end

"""
    unregister_tool!(registry, name) -> ToolRegistry

Remove a tool by name. No-op if the tool doesn't exist.
"""
function unregister_tool!(registry::ToolRegistry, name::AbstractString)
    lock(registry.lock) do
        pop!(registry.tools, String(name), nothing)
    end
    return registry
end

"""Return the `ToolDef` for `name`, or `nothing` if not registered."""
get_tool(registry::ToolRegistry, name::AbstractString) =
    lock(registry.lock) do
        get(registry.tools, String(name), nothing)
    end

"""Return `true` if a tool with `name` is registered."""
has_tool(registry::ToolRegistry, name::AbstractString) =
    lock(registry.lock) do
        haskey(registry.tools, String(name))
    end

"""Return a list of all registered tool names."""
tool_names(registry::ToolRegistry) =
    lock(registry.lock) do
        collect(keys(registry.tools))
    end

"""
    tools_schema(tools) -> Vector{Dict{String,Any}}
    tools_schema(registry) -> Vector{Dict{String,Any}}

Convert tool definitions into OpenAI-compatible function-calling JSON schemas.
"""
function tools_schema(tools::Vector{<:AbstractToolDef})
    return map(tools) do tool
        schema = Dict{String,Any}(
            "type" => "function",
            "name" => tool.name,
            "parameters" => tool.parameters,
        )
        if tool.description !== nothing
            schema["description"] = tool.description
        end
        if tool.strict !== nothing
            schema["strict"] = tool.strict
        end
        schema
    end
end

tools_schema(registry::ToolRegistry) =
    lock(registry.lock) do
        tools_schema(collect(values(registry.tools)))
    end

_schema_properties(schema::AbstractDict) = get(schema, "properties", get(schema, :properties, Dict{String,Any}()))
_schema_required(schema::AbstractDict) = get(schema, "required", get(schema, :required, String[]))
_schema_additional(schema::AbstractDict) =
    get(schema, "additionalProperties", get(schema, :additionalProperties, nothing))

function _string_key_dict(args::Dict)
    out = Dict{String,Any}()
    for (k, v) in args
        out[String(k)] = v
    end
    return out
end

function _json_schema_type(schema::AbstractDict)
    t = get(schema, "type", get(schema, :type, nothing))
    if t isa Vector
        return t
    elseif t === nothing
        return Any[]
    else
        return Any[t]
    end
end

function _coerce_bool(value)
    if value isa Bool
        return value
    elseif value isa AbstractString
        v = lowercase(strip(String(value)))
        if v in ("true", "1", "yes", "on")
            return true
        elseif v in ("false", "0", "no", "off")
            return false
        end
    end
    return value
end

"""Coerce `value` to match the JSON schema type. Handles string, integer, number,
boolean, array, and object types. Returns the value unchanged if coercion isn't possible."""
function _coerce_by_schema(value, schema::AbstractDict)
    types = _json_schema_type(schema)
    isempty(types) && return value
    primary = nothing
    for t in types
        ts = String(t)
        ts == "null" && continue
        primary = ts
        break
    end
    primary === nothing && return value

    if primary == "string"
        return value isa AbstractString ? String(value) : string(value)
    elseif primary == "integer"
        if value isa Integer && !(value isa Bool)
            return Int(value)
        elseif value isa AbstractString
            parsed = tryparse(Int, String(value))
            return parsed === nothing ? value : parsed
        end
    elseif primary == "number"
        if value isa Real && !(value isa Bool)
            return Float64(value)
        elseif value isa AbstractString
            parsed = tryparse(Float64, String(value))
            return parsed === nothing ? value : parsed
        end
    elseif primary == "boolean"
        return _coerce_bool(value)
    elseif primary == "array" && value isa AbstractVector
        item_schema = get(schema, "items", get(schema, :items, nothing))
        if item_schema isa AbstractDict
            return Any[_coerce_by_schema(item, item_schema) for item in value]
        end
    elseif primary == "object" && value isa AbstractDict
        props = _schema_properties(schema)
        out = Dict{String,Any}()
        for (k, v) in pairs(value)
            key = String(k)
            if haskey(props, key)
                out[key] = _coerce_by_schema(v, props[key])
            elseif haskey(props, Symbol(key))
                out[key] = _coerce_by_schema(v, props[Symbol(key)])
            else
                out[key] = v
            end
        end
        return out
    end
    return value
end

"""Recursively validate `value` against a JSON schema, returning a list of error strings.
`path` tracks the current location for error messages (e.g. `"args.name"`)."""
function _validate_value(value, schema::AbstractDict, path::AbstractString)
    errors = String[]
    types = _json_schema_type(schema)
    nullable = any(t -> String(t) == "null", types)
    if value === nothing
        nullable || push!(errors, "$(path) must not be null")
        return errors
    end

    primary = nothing
    for t in types
        t = String(t)
        t == "null" && continue
        primary = t
        break
    end

    if primary === nothing
        return errors
    elseif primary == "string"
        value isa AbstractString || push!(errors, "$(path) must be string")
        enum_values = get(schema, "enum", get(schema, :enum, nothing))
        if enum_values !== nothing
            value in enum_values || push!(errors, "$(path) must be one of $(enum_values)")
        end
    elseif primary == "integer"
        (value isa Integer && !(value isa Bool)) || push!(errors, "$(path) must be integer")
    elseif primary == "number"
        (value isa Real && !(value isa Bool)) || push!(errors, "$(path) must be number")
    elseif primary == "boolean"
        value isa Bool || push!(errors, "$(path) must be boolean")
    elseif primary == "array"
        if !(value isa AbstractVector)
            push!(errors, "$(path) must be array")
        else
            item_schema = get(schema, "items", get(schema, :items, nothing))
            if item_schema isa AbstractDict
                for (i, item) in enumerate(value)
                    append!(errors, _validate_value(item, item_schema, "$(path)[$(i)]"))
                end
            end
        end
    elseif primary == "object"
        if !(value isa AbstractDict)
            push!(errors, "$(path) must be object")
        else
            props = _schema_properties(schema)
            req = _schema_required(schema)
            for key in req
                haskey(value, key) || haskey(value, Symbol(String(key))) ||
                    push!(errors, "$(path).$(key) is required")
            end
            for (k, v) in pairs(value)
                key = String(k)
                if haskey(props, key)
                    append!(errors, _validate_value(v, props[key], "$(path).$(key)"))
                elseif haskey(props, Symbol(key))
                    append!(errors, _validate_value(v, props[Symbol(key)], "$(path).$(key)"))
                end
            end
        end
    end

    return errors
end

"""Coerce each argument value to match the tool's JSON schema property types."""
function _prepare_args(tool::ToolDef, args::Dict{String,Any})
    params = tool.parameters
    props = _schema_properties(params)
    coerced = Dict{String,Any}()
    for (key, value) in pairs(args)
        if haskey(props, key)
            coerced[key] = _coerce_by_schema(value, props[key])
        elseif haskey(props, Symbol(key))
            coerced[key] = _coerce_by_schema(value, props[Symbol(key)])
        else
            coerced[key] = value
        end
    end
    return coerced
end

"""Validate arguments against the tool's schema. Returns a list of error strings (empty if valid).
Checks required fields, unexpected fields (in strict mode), and per-field type validation."""
function _validate_args(tool::ToolDef, args::Dict{String,Any})
    errors = String[]
    params = tool.parameters
    req = _schema_required(params)
    for key in req
        haskey(args, String(key)) || push!(errors, "missing required argument `$(key)`")
    end

    props = _schema_properties(params)
    strict_mode = tool.strict === true || _schema_additional(params) === false
    if strict_mode
        for key in keys(args)
            haskey(props, key) || haskey(props, Symbol(key)) ||
                push!(errors, "unexpected argument `$(key)`")
        end
    end

    for (key, value) in pairs(args)
        if haskey(props, key)
            append!(errors, _validate_value(value, props[key], key))
        elseif haskey(props, Symbol(key))
            append!(errors, _validate_value(value, props[Symbol(key)], key))
        end
    end
    return errors
end

"""
    dispatch_tool(registry, name, args) -> Any

Look up a tool by name, validate and coerce arguments against its JSON schema,
then execute it. Throws `ToolNotFoundError`, `ToolValidationError`, or
`ToolExecutionError` on failure. The tool is looked up under the registry lock,
but execution happens outside the lock.
"""
function dispatch_tool(registry::ToolRegistry, name::AbstractString, args::AbstractDict)
    # Look up tool under lock, but execute outside the lock (execution can be long-running)
    tool = get_tool(registry, name)
    tool === nothing && throw(ToolNotFoundError(String(name), sort(tool_names(registry))))

    normalized = Dict{String,Any}(String(k) => v for (k, v) in pairs(args))
    prepared = _prepare_args(tool, normalized)
    errors = _validate_args(tool, prepared)
    isempty(errors) || throw(ToolValidationError(tool.name, errors))

    try
        return tool.execute(prepared)
    catch e
        throw(ToolExecutionError(tool.name, e, catch_backtrace()))
    end
end

function _schema_expr_from_type(type_expr)
    if type_expr === :String || type_expr === :AbstractString
        return :(Dict{String,Any}("type" => "string"))
    elseif type_expr in (:Bool,)
        return :(Dict{String,Any}("type" => "boolean"))
    elseif type_expr in (:Int, :Int8, :Int16, :Int32, :Int64, :Int128, :UInt, :UInt8, :UInt16, :UInt32, :UInt64)
        return :(Dict{String,Any}("type" => "integer"))
    elseif type_expr in (:Float16, :Float32, :Float64, :Real, :Number)
        return :(Dict{String,Any}("type" => "number"))
    elseif type_expr === :Any
        return :(Dict{String,Any}())
    elseif type_expr isa Expr && type_expr.head == :curly
        base = type_expr.args[1]
        if base in (:Vector, :AbstractVector, :Array)
            item_schema =
                length(type_expr.args) >= 2 ? _schema_expr_from_type(type_expr.args[2]) : :(Dict{String,Any}())
            return :(Dict{String,Any}("type" => "array", "items" => $item_schema))
        elseif base in (:Dict, :AbstractDict)
            return :(Dict{String,Any}("type" => "object"))
        elseif base === :Union
            non_null = [arg for arg in type_expr.args[2:end] if !(arg === :Nothing)]
            if length(non_null) == 1
                base_schema = _schema_expr_from_type(non_null[1])
                return quote
                    local _schema = $base_schema
                    if haskey(_schema, "type")
                        _schema["type"] = Any[_schema["type"], "null"]
                    end
                    _schema
                end
            end
        end
    end
    return :(Dict{String,Any}("type" => "string"))
end

function _extract_docstring(body)
    if body isa Expr && body.head == :block
        for stmt in body.args
            stmt isa LineNumberNode && continue
            if stmt isa String
                return stmt
            end
            break
        end
    end
    return nothing
end

function _parse_macro_arg(arg)
    has_default = false
    default_expr = nothing
    type_expr = :Any
    name = nothing

    if arg isa Symbol
        name = arg
    elseif arg isa Expr && arg.head == :(::)
        name = arg.args[1]
        type_expr = arg.args[2]
    elseif arg isa Expr && arg.head == :(=)
        has_default = true
        default_expr = arg.args[2]
        left = arg.args[1]
        if left isa Symbol
            name = left
        elseif left isa Expr && left.head == :(::)
            name = left.args[1]
            type_expr = left.args[2]
        end
    elseif arg isa Expr && arg.head == :kw
        error("@tool does not support keyword arguments yet")
    end

    name isa Symbol || error("@tool could not parse argument: $(arg)")
    return (name = name, type_expr = type_expr, has_default = has_default, default_expr = default_expr)
end

"""
    @tool [return_direct=true] [max_output_chars=4096] [strict=true] function f(args...) ... end

Define a Julia function and create `<function_name>_tool::ToolDef` in the same scope.
"""
macro tool(args...)
    return_direct_expr = false
    max_output_chars_expr = 0
    strict_expr = nothing
    funcdef = nothing

    for arg in args
        if arg isa Expr && arg.head == :(=) && arg.args[1] == :return_direct
            return_direct_expr = arg.args[2]
        elseif arg isa Expr && arg.head == :(=) && (arg.args[1] == :max_output_chars || arg.args[1] == :max_output)
            max_output_chars_expr = arg.args[2]
        elseif arg isa Expr && arg.head == :(=) && arg.args[1] == :strict
            strict_expr = arg.args[2]
        elseif arg isa Expr && arg.head in (:function, :(=))
            funcdef = arg
        else
            error("@tool: unexpected argument $(arg)")
        end
    end

    isnothing(funcdef) && error("@tool expects a function definition")

    sig = funcdef.head == :function ? funcdef.args[1] : funcdef.args[1]
    body = funcdef.head == :function ? funcdef.args[2] : funcdef.args[2]
    sig isa Expr && sig.head == :call || error("@tool expects a standard function signature")

    fname = sig.args[1]
    bare_name = fname isa Symbol ? fname : (fname isa Expr ? fname.args[end] : fname)
    bare_name isa Symbol || error("@tool could not parse function name")
    tool_var = Symbol(bare_name, :_tool)

    arg_specs = [_parse_macro_arg(arg) for arg in sig.args[2:end]]
    properties_entries = Any[]
    required_entries = String[]
    call_args = Any[]

    for spec in arg_specs
        key = String(spec.name)
        push!(properties_entries, :($key => $(_schema_expr_from_type(spec.type_expr))))
        if spec.has_default
            push!(call_args, :(get(args, $key, $(esc(spec.default_expr)))))
        else
            push!(required_entries, key)
            push!(call_args, :(args[$key]))
        end
    end

    docs = _extract_docstring(body)
    docs_expr = docs === nothing ? :nothing : docs

    tool_init = quote
        local _properties = Dict{String,Any}($(properties_entries...))
        local _params = Dict{String,Any}("type" => "object", "properties" => _properties)
        local _required = String[$(required_entries...)]
        isempty(_required) || (_params["required"] = _required)

        local _execute = (args::Dict{String,Any}) -> begin
            $(Expr(:call, esc(fname), call_args...))
        end

        $(esc(tool_var)) = ToolDef(
            name = $(string(bare_name)),
            parameters = _params,
            execute = _execute,
            description = $docs_expr,
            return_direct = $(esc(return_direct_expr)),
            max_output_chars = $(esc(max_output_chars_expr)),
            strict = $(esc(strict_expr)),
        )
    end

    return Expr(:block, esc(funcdef), tool_init)
end

end
