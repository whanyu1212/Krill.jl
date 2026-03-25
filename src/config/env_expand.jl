"""
    expand_env(s::AbstractString)

Replace `\$VAR` references in a string with their values from `ENV`.
Unset variables are left as-is.
"""
expand_env(s::AbstractString) =
    replace(s, r"\$([A-Z_][A-Z0-9_]*)" => m -> get(ENV, m[2:end], m))
expand_env(x) = x

"""
    expand_env_deep!(d::Dict)

Recursively expand `\$VAR` references in all string values of a nested Dict
(typically a parsed TOML configuration).
"""
function expand_env_deep!(d::Dict)
    for (k, v) in d
        if v isa AbstractString
            d[k] = expand_env(v)
        elseif v isa Dict
            expand_env_deep!(v)
        elseif v isa Vector
            d[k] = [x isa AbstractString ? expand_env(x) :
                    x isa Dict ? expand_env_deep!(x) : x for x in v]
        end
    end
    return d
end
