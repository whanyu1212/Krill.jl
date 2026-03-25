"""
    build_channels(cfg::Dict) -> Vector{AbstractChannel}

Read channel sections from a krill.toml config dict and construct enabled
channel instances. Errors if no channels are enabled.
"""
function build_channels(cfg::Dict)
    channels = AbstractChannel[]

    # Telegram (polling)
    tg = get_cfg(cfg, "telegram"; default=nothing)
    if tg isa Dict && get(tg, "enabled", false)
        token = get(tg, "bot_token", "")
        isempty(token) && error("telegram.bot_token is empty — set it in krill.toml or .env")
        allow_from = String.(get(tg, "allow_from", String[]))
        ch = TelegramChannel(token; allow_from=allow_from)
        push!(channels, ch)
        @info "Channel enabled: Telegram" allow_from=allow_from
    end

    # Discord
    dc = get_cfg(cfg, "discord"; default=nothing)
    if dc isa Dict && get(dc, "enabled", false)
        token = get(dc, "bot_token", "")
        isempty(token) && error("discord.bot_token is empty — set it in krill.toml or .env")
        allow_from = String.(get(dc, "allow_from", String[]))
        ch = DiscordChannel(token; allow_from=allow_from)
        push!(channels, ch)
        @info "Channel enabled: Discord" allow_from=allow_from
    end

    isempty(channels) && error(
        "No channels enabled in krill.toml. " *
        "Set enabled = true under [telegram] or [discord]."
    )
    return channels
end
