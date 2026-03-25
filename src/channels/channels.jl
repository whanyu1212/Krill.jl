module Channels

include("telegram.jl")
include("discord.jl")

using .Telegram: TelegramClient, TelegramAPIError, TelegramChannel, TelegramWebhookChannel,
    get_updates, send_message, send_chat_action, set_webhook, delete_webhook,
    run_polling, normalize_update, make_telegram_sender

using .Discord: DiscordClient, DiscordAPIError, DiscordChannel,
    discord_send_message, discord_trigger_typing

export Telegram, TelegramClient, TelegramAPIError, TelegramChannel, TelegramWebhookChannel,
    get_updates, send_message, send_chat_action, set_webhook, delete_webhook,
    run_polling, normalize_update, make_telegram_sender,
    Discord, DiscordClient, DiscordAPIError, DiscordChannel,
    discord_send_message, discord_trigger_typing

end
