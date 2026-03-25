module Dedup

export BoundedDedup, seen!, has_seen

"""
    BoundedDedup(capacity=1000)

Bounded set for deduplicating integer IDs (e.g. Telegram `update_id`).
Stores up to `capacity` entries; when full, the oldest entry is evicted.

Use [`seen!`](@ref) to record an ID and check if it was already known,
and [`has_seen`](@ref) for a read-only membership check.
"""
mutable struct BoundedDedup
    capacity::Int
    ring::Vector{Int}
    set::Set{Int}
    index::Int
end

function BoundedDedup(capacity::Int=1000)
    capacity > 0 || throw(ArgumentError("capacity must be > 0"))
    return BoundedDedup(capacity, Vector{Int}(undef, capacity), Set{Int}(), 0)
end

"""
    has_seen(d::BoundedDedup, id::Int) -> Bool

Return `true` if `id` has been recorded, `false` otherwise.
"""
has_seen(d::BoundedDedup, id::Int)::Bool = id in d.set

"""
    seen!(d::BoundedDedup, id::Int) -> Bool

Record `id` and return `true` if it is new (first time seen).
Return `false` if it was already in the set (duplicate).
"""
function seen!(d::BoundedDedup, id::Int)::Bool
    id in d.set && return false

    d.index += 1
    if d.index > d.capacity
        d.index = 1
    end

    if length(d.set) >= d.capacity
        old = d.ring[d.index]
        delete!(d.set, old)
    end

    d.ring[d.index] = id
    push!(d.set, id)
    return true
end

end
