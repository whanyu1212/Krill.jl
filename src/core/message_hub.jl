module MessageHub

using ..Types: InboundMessage, OutboundMessage

export MessageHubState,
    publish_inbound!,
    publish_outbound!,
    try_publish_inbound!,
    try_publish_outbound!,
    take_inbound!,
    take_outbound!,
    try_take_inbound!,
    try_take_outbound!

"""
    MessageHubState(; inbound_capacity=32, outbound_capacity=32)

Typed FIFO message queues that decouple producers from consumers.
Inbound queue carries [`InboundMessage`](@ref), outbound carries [`OutboundMessage`](@ref).

Throws `ArgumentError` if either capacity is not positive.
"""
struct MessageHubState
    inbound::Channel{InboundMessage}
    outbound::Channel{OutboundMessage}
end

function MessageHubState(; inbound_capacity::Int=32, outbound_capacity::Int=32)
    inbound_capacity > 0 || throw(ArgumentError("inbound_capacity must be > 0"))
    outbound_capacity > 0 || throw(ArgumentError("outbound_capacity must be > 0"))
    return MessageHubState(
        Channel{InboundMessage}(inbound_capacity),
        Channel{OutboundMessage}(outbound_capacity),
    )
end

"""
    publish_inbound!(hub, msg)

Enqueue an [`InboundMessage`](@ref). Blocks if the inbound channel is full.
"""
publish_inbound!(hub::MessageHubState, msg::InboundMessage) = put!(hub.inbound, msg)

"""
    publish_outbound!(hub, msg)

Enqueue an [`OutboundMessage`](@ref). Blocks if the outbound channel is full.
"""
publish_outbound!(hub::MessageHubState, msg::OutboundMessage) = put!(hub.outbound, msg)

"""
    take_inbound!(hub) -> InboundMessage

Dequeue the next inbound message. Blocks until one is available.
"""
take_inbound!(hub::MessageHubState) = take!(hub.inbound)

"""
    take_outbound!(hub) -> OutboundMessage

Dequeue the next outbound message. Blocks until one is available.
"""
take_outbound!(hub::MessageHubState) = take!(hub.outbound)

"""
    try_publish_inbound!(hub, msg) -> Bool

Non-blocking enqueue. Returns `true` if the message was published, `false` if the
inbound queue is full. Safe for single-producer use.
"""
function try_publish_inbound!(hub::MessageHubState, msg::InboundMessage)
    ch = hub.inbound
    Base.n_avail(ch) < ch.sz_max || return false
    put!(ch, msg)
    return true
end

"""
    try_publish_outbound!(hub, msg) -> Bool

Non-blocking enqueue. Returns `true` if the message was published, `false` if the
outbound queue is full. Safe for single-producer use.
"""
function try_publish_outbound!(hub::MessageHubState, msg::OutboundMessage)
    ch = hub.outbound
    Base.n_avail(ch) < ch.sz_max || return false
    put!(ch, msg)
    return true
end

"""
    try_take_inbound!(hub) -> Union{InboundMessage, Nothing}

Non-blocking dequeue. Returns `nothing` if the inbound queue is empty.
"""
try_take_inbound!(hub::MessageHubState) = isready(hub.inbound) ? take!(hub.inbound) : nothing

"""
    try_take_outbound!(hub) -> Union{OutboundMessage, Nothing}

Non-blocking dequeue. Returns `nothing` if the outbound queue is empty.
"""
try_take_outbound!(hub::MessageHubState) = isready(hub.outbound) ? take!(hub.outbound) : nothing

end
