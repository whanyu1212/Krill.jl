using Krill
using Krill: AbstractChannel, ContentPart, TextPart, BinaryPart,
    SessionCancelScope, request_cancel!, is_cancelled, clear_cancel!,
    normalize_update, message_text
using Test
using UUIDs
using Dates
using JSON3

# ============================================================================
# Media/Callback normalization tests
# ============================================================================

@testset "Media & Callback Normalization" begin

    # --- Telegram photo ---
    @testset "Telegram photo message extracts BinaryPart" begin
        update = Dict(
            :update_id => 1,
            :message => Dict(
                :message_id => 10,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                :photo => [
                    Dict(:file_id => "small_id", :file_unique_id => "s1", :width => 90, :height => 90),
                    Dict(:file_id => "large_id", :file_unique_id => "s2", :width => 800, :height => 600),
                ],
                :caption => "my photo",
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test message_text(msg) == "my photo"
        @test length(msg.content_parts) == 2
        @test msg.content_parts[1] isa TextPart
        @test msg.content_parts[2] isa BinaryPart
        @test msg.content_parts[2].media_type == "image/jpeg"
        @test msg.content_parts[2].filename == "large_id"  # file_id stored in filename
    end

    # --- Telegram document ---
    @testset "Telegram document message extracts BinaryPart" begin
        update = Dict(
            :update_id => 2,
            :message => Dict(
                :message_id => 11,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                :document => Dict(
                    :file_id => "doc_file_id",
                    :file_unique_id => "d1",
                    :mime_type => "application/pdf",
                    :file_name => "report.pdf",
                ),
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test length(msg.content_parts) == 1  # no text, just document
        @test msg.content_parts[1] isa BinaryPart
        @test msg.content_parts[1].media_type == "application/pdf"
    end

    # --- Telegram voice ---
    @testset "Telegram voice message extracts BinaryPart" begin
        update = Dict(
            :update_id => 3,
            :message => Dict(
                :message_id => 12,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                :voice => Dict(
                    :file_id => "voice_id",
                    :file_unique_id => "v1",
                    :duration => 5,
                    :mime_type => "audio/ogg",
                ),
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test length(msg.content_parts) == 1
        @test msg.content_parts[1] isa BinaryPart
        @test msg.content_parts[1].media_type == "audio/ogg"
    end

    # --- Telegram video ---
    @testset "Telegram video extracts BinaryPart" begin
        update = Dict(
            :update_id => 4,
            :message => Dict(
                :message_id => 13,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                :video => Dict(
                    :file_id => "video_id",
                    :file_unique_id => "vid1",
                    :width => 1920,
                    :height => 1080,
                    :mime_type => "video/mp4",
                ),
                :caption => "check this out",
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test message_text(msg) == "check this out"
        @test length(msg.content_parts) == 2
        @test msg.content_parts[2] isa BinaryPart
        @test msg.content_parts[2].media_type == "video/mp4"
    end

    # --- Telegram sticker ---
    @testset "Telegram sticker extracts BinaryPart" begin
        update = Dict(
            :update_id => 5,
            :message => Dict(
                :message_id => 14,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                :sticker => Dict(
                    :file_id => "sticker_id",
                    :file_unique_id => "st1",
                    :width => 512,
                    :height => 512,
                    :is_animated => false,
                ),
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test length(msg.content_parts) == 1
        @test msg.content_parts[1] isa BinaryPart
        @test msg.content_parts[1].media_type == "image/webp"
    end

    # --- Telegram text+photo combined ---
    @testset "Telegram text message still works" begin
        update = Dict(
            :update_id => 6,
            :message => Dict(
                :message_id => 15,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :text => "hello world",
                :date => 1000,
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test message_text(msg) == "hello world"
        @test length(msg.content_parts) == 1
        @test msg.content_parts[1] isa TextPart
    end

    # --- Telegram callback_query ---
    @testset "Telegram callback_query produces InboundMessage" begin
        update = Dict(
            :update_id => 7,
            :callback_query => Dict(
                :id => "cb123",
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :data => "button_clicked",
                :message => Dict(
                    :message_id => 20,
                    :chat => Dict(:id => 42, :type => "private"),
                    :date => 1000,
                ),
            ),
        )
        msg = normalize_update(update)
        @test msg !== nothing
        @test message_text(msg) == "button_clicked"
        @test msg.metadata["type"] == "callback_query"
        @test msg.metadata["callback_query_id"] == "cb123"
        @test msg.chat_id == "42"
        @test msg.user_id == "100"
    end

    # --- Telegram message with no text and no media returns nothing ---
    @testset "Telegram empty message returns nothing" begin
        update = Dict(
            :update_id => 8,
            :message => Dict(
                :message_id => 16,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :date => 1000,
                # no text, no photo, no document, etc.
            ),
        )
        msg = normalize_update(update)
        @test msg === nothing
    end

    # --- Discord attachment ---
    @testset "Discord message with attachments extracts BinaryPart" begin
        event = Dict(
            :content => "look at this",
            :author => Dict(:id => "111", :username => "user1", :bot => false),
            :channel_id => "222",
            :guild_id => "333",
            :id => "444",
            :attachments => [
                Dict(
                    :url => "https://cdn.discord.com/img.png",
                    :content_type => "image/png",
                    :filename => "img.png",
                ),
            ],
        )
        msg = Krill.Channels.Discord.normalize_discord_event(event)
        @test msg !== nothing
        @test length(msg.content_parts) == 2
        @test msg.content_parts[1] isa TextPart
        @test msg.content_parts[2] isa BinaryPart
        @test msg.content_parts[2].media_type == "image/png"
        @test msg.content_parts[2].url == "https://cdn.discord.com/img.png"
    end

    # --- Discord message without attachments ---
    @testset "Discord text-only message still works" begin
        event = Dict(
            :content => "hello",
            :author => Dict(:id => "111", :username => "user1", :bot => false),
            :channel_id => "222",
            :guild_id => "333",
            :id => "444",
        )
        msg = Krill.Channels.Discord.normalize_discord_event(event)
        @test msg !== nothing
        @test length(msg.content_parts) == 1
        @test msg.content_parts[1] isa TextPart
    end

    # --- InboundMessage content_parts kwarg ---
    @testset "InboundMessage accepts content_parts kwarg" begin
        parts = ContentPart[TextPart("hi"), BinaryPart("image/png", "http://img", nothing, "img.png")]
        msg = InboundMessage(
            channel = :test,
            session_key = "test:1",
            user_id = "1",
            chat_id = "1",
            content_parts = parts,
        )
        @test length(msg.content_parts) == 2
        @test msg.content_parts[1] isa TextPart
        @test msg.content_parts[2] isa BinaryPart
    end
end

# ============================================================================
# Tool result caching tests
# ============================================================================

@testset "Tool Result Caching" begin
    @testset "cache key produces consistent hashes" begin
        args1 = Dict{String,Any}("path" => "/tmp/foo.txt")
        args2 = Dict{String,Any}("path" => "/tmp/foo.txt")
        @test hash(("read_file", args1)) == hash(("read_file", args2))
    end

    @testset "different args produce different hashes" begin
        args1 = Dict{String,Any}("path" => "/tmp/foo.txt")
        args2 = Dict{String,Any}("path" => "/tmp/bar.txt")
        @test hash(("read_file", args1)) != hash(("read_file", args2))
    end

    @testset "different tool names produce different hashes" begin
        args = Dict{String,Any}("path" => "/tmp/foo.txt")
        @test hash(("read_file", args)) != hash(("write_file", args))
    end

    @testset "cache stores and retrieves results" begin
        cache = Dict{UInt64,Tuple{String,Bool}}()
        key = hash(("test_tool", Dict{String,Any}("a" => 1)))
        cache[key] = ("result text", false)
        @test haskey(cache, key)
        result_text, is_error = cache[key]
        @test result_text == "result text"
        @test is_error == false
    end
end

# ============================================================================
# Mid-turn cancellation tests
# ============================================================================

@testset "Mid-Turn Cancellation" begin
    @testset "SessionCancelScope constructor" begin
        scope = SessionCancelScope()
        @test scope isa SessionCancelScope
        @test isempty(scope.flags)
    end

    @testset "clear_cancel! creates fresh flag" begin
        scope = SessionCancelScope()
        flag = clear_cancel!(scope, "session:1")
        @test flag isa Threads.Atomic{Bool}
        @test flag[] == false
        @test !is_cancelled(scope, "session:1")
    end

    @testset "request_cancel! sets flag" begin
        scope = SessionCancelScope()
        clear_cancel!(scope, "session:1")
        @test !is_cancelled(scope, "session:1")

        result = request_cancel!(scope, "session:1")
        @test result == true  # flag existed
        @test is_cancelled(scope, "session:1")
    end

    @testset "request_cancel! with no existing flag creates one" begin
        scope = SessionCancelScope()
        result = request_cancel!(scope, "session:new")
        @test result == false  # no flag existed before
        @test is_cancelled(scope, "session:new")
    end

    @testset "clear_cancel! resets after cancellation" begin
        scope = SessionCancelScope()
        clear_cancel!(scope, "session:1")
        request_cancel!(scope, "session:1")
        @test is_cancelled(scope, "session:1")

        clear_cancel!(scope, "session:1")
        @test !is_cancelled(scope, "session:1")
    end

    @testset "is_cancelled returns false for unknown session" begin
        scope = SessionCancelScope()
        @test !is_cancelled(scope, "unknown:session")
    end

    @testset "cancellation is per-session" begin
        scope = SessionCancelScope()
        clear_cancel!(scope, "session:1")
        clear_cancel!(scope, "session:2")

        request_cancel!(scope, "session:1")
        @test is_cancelled(scope, "session:1")
        @test !is_cancelled(scope, "session:2")
    end

    @testset "concurrent cancel/clear is safe" begin
        scope = SessionCancelScope()
        clear_cancel!(scope, "session:1")

        tasks = Task[]
        for i in 1:20
            push!(tasks, Threads.@spawn begin
                if i % 2 == 0
                    request_cancel!(scope, "session:1")
                else
                    clear_cancel!(scope, "session:1")
                end
            end)
        end
        for t in tasks
            wait(t)
        end
        # Should not crash — final state depends on ordering
        @test is_cancelled(scope, "session:1") isa Bool
    end
end
