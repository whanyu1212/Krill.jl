module Echo

using ..Types: InboundMessage, OutboundMessage, message_text
using ..MessageHub: MessageHubState, try_take_inbound!, publish_outbound!

export run_echo_loop!

"""
    run_echo_loop!(hub, running::Ref{Bool})

Minimal consumer that echoes inbound messages back as outbound replies.
Sets `correlation_id` to the inbound message's `message_id` for tracing.
Drains any remaining inbound messages after `running` is set to `false`.
"""
function run_echo_loop!(hub::MessageHubState, running::Ref{Bool})
    while running[]
        msg = try_take_inbound!(hub)
        if msg === nothing
            sleep(0.01)
            continue
        end
        _echo_reply!(hub, msg)
    end
    _drain_inbound!(hub)
end

function _echo_reply!(hub::MessageHubState, msg::InboundMessage)
    text = message_text(msg)
    reply = OutboundMessage(
        channel=msg.channel,
        session_key=msg.session_key,
        chat_id=msg.chat_id,
        text=text,
        correlation_id=msg.message_id,
    )
    publish_outbound!(hub, reply)
end

function _drain_inbound!(hub::MessageHubState)
    while true
        msg = try_take_inbound!(hub)
        msg === nothing && break
        _echo_reply!(hub, msg)
    end
end

end
