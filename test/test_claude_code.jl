using Krill
using Krill: ChannelManagerState, OutboundMessage, DeliveryPolicy,
    MessageHubState, publish_outbound!
using Test
using UUIDs
using Dates
using JSON3

# ============================================================================
# Unit tests for Claude Code builtin tool (no actual claude CLI calls)
# ============================================================================

@testset "Claude Code Tool" begin

    # ============================================================================
    # _parse_stream_json_result
    # ============================================================================

    @testset "parse stream-json result" begin
        parse = Krill.Core.BuiltinTools._parse_stream_json_result

        @testset "success result" begin
            lines = [
                """{"type":"system","subtype":"init","session_id":"abc-123"}""",
                """{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}""",
                """{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.05,"session_id":"abc-123"}""",
            ]
            r = parse(lines)
            @test contains(r, "done")
            @test contains(r, "\$0.05")
            @test contains(r, "abc-123")
        end

        @testset "error result" begin
            lines = [
                """{"type":"result","subtype":"error","is_error":true,"result":"something broke","total_cost_usd":0.01,"session_id":"xyz"}""",
            ]
            r = parse(lines)
            @test contains(r, "Error")
            @test contains(r, "something broke")
            @test contains(r, "\$0.01")
        end

        @testset "with rate limit event" begin
            lines = [
                """{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1774328400,"rateLimitType":"five_hour"}}""",
                """{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.02,"session_id":"s1"}""",
            ]
            r = parse(lines)
            @test contains(r, "ok")
            @test contains(r, "Rate limit: allowed")
            @test contains(r, "resets")
        end

        @testset "rate limited status" begin
            lines = [
                """{"type":"rate_limit_event","rate_limit_info":{"status":"rate_limited","resetsAt":1774328400}}""",
                """{"type":"result","subtype":"success","is_error":false,"result":"partial","total_cost_usd":0.0,"session_id":"s2"}""",
            ]
            r = parse(lines)
            @test contains(r, "Rate limit: rate_limited")
        end

        @testset "no result line falls back to raw" begin
            lines = ["line1", "line2", "line3"]
            r = parse(lines)
            @test r == "line1\nline2\nline3"
        end

        @testset "empty lines" begin
            r = parse(String[])
            @test r == ""
        end

        @testset "malformed JSON ignored" begin
            lines = [
                "not json",
                """{"type":"result","subtype":"success","is_error":false,"result":"found","total_cost_usd":0.01,"session_id":"s3"}""",
            ]
            r = parse(lines)
            @test contains(r, "found")
        end
    end

    # ============================================================================
    # _extract_progress_event
    # ============================================================================

    @testset "extract progress event" begin
        extract = Krill.Core.BuiltinTools._extract_progress_event

        @testset "tool_use event" begin
            line = """{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"""
            r = extract(line)
            @test r == "Using Read..."
        end

        @testset "text event returns nothing" begin
            line = """{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"""
            r = extract(line)
            @test r === nothing
        end

        @testset "rate limit not allowed" begin
            line = """{"type":"rate_limit_event","rate_limit_info":{"status":"rate_limited"}}"""
            r = extract(line)
            @test r == "Rate limit status: rate_limited"
        end

        @testset "rate limit allowed returns nothing" begin
            line = """{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"""
            r = extract(line)
            @test r === nothing
        end

        @testset "system event returns nothing" begin
            line = """{"type":"system","subtype":"init"}"""
            r = extract(line)
            @test r === nothing
        end

        @testset "malformed JSON returns nothing" begin
            r = extract("not json at all")
            @test r === nothing
        end

        @testset "result event returns nothing" begin
            line = """{"type":"result","subtype":"success"}"""
            r = extract(line)
            @test r === nothing
        end
    end

    # ============================================================================
    # Tool registration
    # ============================================================================

    @testset "tool registration" begin
        @testset "claude_code not registered when disabled" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_claude_code = false)
            names = [d.name for d in defs]
            @test !("claude_code" in names)
        end

        @testset "claude_code registered when enabled" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_claude_code = true)
            names = [d.name for d in defs]
            @test "claude_code" in names
        end

        @testset "claude_code schema has required fields" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_claude_code = true)
            cc = filter(d -> d.name == "claude_code", defs)
            @test length(cc) == 1
            params = cc[1].parameters
            @test params["type"] == "object"
            props = params["properties"]
            @test haskey(props, "task")
            @test haskey(props, "session_id")
            @test haskey(props, "resume")
            @test params["required"] == Any["task"]
        end
    end

    # ============================================================================
    # Input validation (without actually calling claude)
    # ============================================================================

    @testset "input validation" begin
        @testset "empty task" begin
            reg = Krill.Core.ToolRegistry()
            Krill.Core.register_builtin_tools!(reg; enable_claude_code = true, workspace = "/tmp")
            result = Krill.Core.dispatch_tool(reg, "claude_code", Dict{String,Any}("task" => ""))
            @test contains(result, "Error")
            @test contains(result, "must not be empty")
        end

        @testset "missing task throws" begin
            reg = Krill.Core.ToolRegistry()
            Krill.Core.register_builtin_tools!(reg; enable_claude_code = true, workspace = "/tmp")
            @test_throws Exception Krill.Core.dispatch_tool(reg, "claude_code", Dict{String,Any}())
        end
    end

    # ============================================================================
    # github tool (quick sanity check)
    # ============================================================================

    @testset "github tool" begin
        reg = Krill.Core.ToolRegistry()
        defs = Krill.Core.register_builtin_tools!(reg)
        names = [d.name for d in defs]
        @test "github" in names

        # Empty command
        result = Krill.Core.dispatch_tool(reg, "github", Dict{String,Any}("command" => ""))
        @test contains(result, "Error")
    end

    # ============================================================================
    # Codex tool — _parse_codex_result
    # ============================================================================

    @testset "parse codex result" begin
        parse = Krill.Core.BuiltinTools._parse_codex_result

        @testset "success with message and usage" begin
            lines = [
                """{"type":"thread.started","thread_id":"tid-123"}""",
                """{"type":"turn.started"}""",
                """{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"done"}}""",
                """{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":50,"cached_input_tokens":800}}""",
            ]
            r = parse(lines)
            @test contains(r, "done")
            @test contains(r, "1000 in")
            @test contains(r, "50 out")
            @test contains(r, "800 cached")
            @test contains(r, "tid-123")
        end

        @testset "error result" begin
            lines = [
                """{"type":"thread.started","thread_id":"tid-456"}""",
                """{"type":"turn.started"}""",
                """{"type":"error","message":"model not found"}""",
                """{"type":"turn.failed","error":{"message":"model not found"}}""",
            ]
            r = parse(lines)
            @test contains(r, "Error")
            @test contains(r, "model not found")
        end

        @testset "multiple turns accumulate tokens" begin
            lines = [
                """{"type":"thread.started","thread_id":"tid-789"}""",
                """{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":0}}""",
                """{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"step1"}}""",
                """{"type":"turn.completed","usage":{"input_tokens":200,"output_tokens":20,"cached_input_tokens":50}}""",
                """{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"final"}}""",
            ]
            r = parse(lines)
            @test contains(r, "final")  # last message
            @test contains(r, "300 in")  # 100 + 200
            @test contains(r, "30 out")  # 10 + 20
            @test contains(r, "50 cached")
        end

        @testset "no output" begin
            lines = [
                """{"type":"thread.started","thread_id":"tid-000"}""",
                """{"type":"turn.completed","usage":{"input_tokens":0,"output_tokens":0,"cached_input_tokens":0}}""",
            ]
            r = parse(lines)
            @test contains(r, "(no output)")
        end

        @testset "empty lines" begin
            r = parse(String[])
            @test contains(r, "(no output)")
        end

        @testset "malformed JSON ignored" begin
            lines = [
                "not json",
                """{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}""",
                """{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1,"cached_input_tokens":0}}""",
            ]
            r = parse(lines)
            @test contains(r, "ok")
            @test contains(r, "5 in")
        end

        @testset "command_execution items ignored for result" begin
            lines = [
                """{"type":"item.completed","item":{"type":"command_execution","command":"ls","status":"completed"}}""",
                """{"type":"item.completed","item":{"type":"agent_message","text":"listed files"}}""",
                """{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":0}}""",
            ]
            r = parse(lines)
            @test contains(r, "listed files")
            @test !contains(r, "command_execution")
        end
    end

    # ============================================================================
    # Codex — _extract_codex_progress
    # ============================================================================

    @testset "extract codex progress" begin
        extract = Krill.Core.BuiltinTools._extract_codex_progress

        @testset "command execution" begin
            line = """{"type":"item.completed","item":{"type":"command_execution","command":"git status","status":"completed"}}"""
            r = extract(line)
            @test r == "Ran: git status (completed)"
        end

        @testset "agent message returns nothing" begin
            line = """{"type":"item.completed","item":{"type":"agent_message","text":"thinking"}}"""
            r = extract(line)
            @test r === nothing
        end

        @testset "error event" begin
            line = """{"type":"error","message":"boom"}"""
            r = extract(line)
            @test r == "Codex error encountered"
        end

        @testset "turn.failed event" begin
            line = """{"type":"turn.failed","error":{"message":"fail"}}"""
            r = extract(line)
            @test r == "Codex error encountered"
        end

        @testset "malformed JSON" begin
            r = extract("not json")
            @test r === nothing
        end

        @testset "long command truncated" begin
            long_cmd = "a" ^ 100
            line = """{"type":"item.completed","item":{"type":"command_execution","command":"$(long_cmd)","status":"completed"}}"""
            r = extract(line)
            @test length(r) < 120
            @test endswith(r, "(completed)")
        end
    end

    # ============================================================================
    # Codex tool registration
    # ============================================================================

    @testset "codex tool registration" begin
        @testset "codex not registered when disabled" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_codex = false)
            names = [d.name for d in defs]
            @test !("codex" in names)
        end

        @testset "codex registered when enabled" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_codex = true)
            names = [d.name for d in defs]
            @test "codex" in names
        end

        @testset "codex schema has required fields" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_codex = true)
            cx = filter(d -> d.name == "codex", defs)
            @test length(cx) == 1
            params = cx[1].parameters
            @test params["type"] == "object"
            props = params["properties"]
            @test haskey(props, "task")
            @test haskey(props, "resume")
            @test params["required"] == Any["task"]
        end

        @testset "both claude_code and codex can coexist" begin
            reg = Krill.Core.ToolRegistry()
            defs = Krill.Core.register_builtin_tools!(reg; enable_claude_code = true, enable_codex = true)
            names = [d.name for d in defs]
            @test "claude_code" in names
            @test "codex" in names
        end
    end

    # ============================================================================
    # Codex input validation
    # ============================================================================

    @testset "codex input validation" begin
        @testset "empty task" begin
            reg = Krill.Core.ToolRegistry()
            Krill.Core.register_builtin_tools!(reg; enable_codex = true, workspace = "/tmp")
            result = Krill.Core.dispatch_tool(reg, "codex", Dict{String,Any}("task" => ""))
            @test contains(result, "Error")
            @test contains(result, "must not be empty")
        end

        @testset "missing task throws" begin
            reg = Krill.Core.ToolRegistry()
            Krill.Core.register_builtin_tools!(reg; enable_codex = true, workspace = "/tmp")
            @test_throws Exception Krill.Core.dispatch_tool(reg, "codex", Dict{String,Any}())
        end
    end
end  # top-level testset
