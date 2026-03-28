function _message_tool_impl(
    args::Dict{String,Any};
    send_message_fn::Union{Nothing,Function},
)
    if send_message_fn === nothing
        return "Error: message tool is unavailable"
    end

    chat_id = get(args, "chat_id", nothing)
    if !(chat_id isa AbstractString || chat_id isa Integer)
        return "Error: `chat_id` must be a string or integer"
    end
    text = get(args, "text", nothing)
    text isa AbstractString || return "Error: `text` must be a string"

    disable_web_page_preview = _parse_bool(
        get(args, "disable_web_page_preview", false);
        default = false,
    )

    try
        send_message_fn(string(chat_id), text; disable_web_page_preview = disable_web_page_preview)
    catch e
        return "Error sending message: $(sprint(showerror, e))"
    end
    return "Sent message to $(chat_id)"
end
