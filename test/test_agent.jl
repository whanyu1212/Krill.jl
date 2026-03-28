@isdefined(Krill) || using Krill
using Krill: ToolRegistry, ToolDef, register_tool!
using Test
using Krill.Telegram: HTTP, JSON3

# Internal modules for white-box tests; use local names to avoid conflicts when
# included from runtests.jl which may have already defined these.
const _Agent_MCPServer = Krill.MCP.MCPServer
const _LLM = Krill.LLM

# ============================================================================
# RetryConfig
# ============================================================================

@testset "RetryConfig defaults" begin
    r = RetryConfig()
    @test r.max_retries == 3
    @test r.base_delay_s == 0.5
    @test r.max_delay_s == 60.0
    @test r.multiplier == 2.0
    @test r.jitter == true
    @test 429 in r.retriable_status_codes
    @test 500 in r.retriable_status_codes
    @test 529 in r.retriable_status_codes
    @test !(200 in r.retriable_status_codes)
end

@testset "RetryConfig custom values" begin
    r = RetryConfig(
        max_retries = 5,
        base_delay_s = 1.0,
        max_delay_s = 30.0,
        multiplier = 3.0,
        jitter = false,
        retriable_status_codes = Set{Int}([503]),
    )
    @test r.max_retries == 5
    @test r.base_delay_s == 1.0
    @test r.max_delay_s == 30.0
    @test r.multiplier == 3.0
    @test r.jitter == false
    @test r.retriable_status_codes == Set{Int}([503])
end

@testset "RetryConfig validation" begin
    @test_throws ArgumentError RetryConfig(max_retries = -1)
    @test_throws ArgumentError RetryConfig(base_delay_s = -0.1)
    @test_throws ArgumentError RetryConfig(max_delay_s = -1.0)
    @test_throws ArgumentError RetryConfig(multiplier = 0.9)
end

# ============================================================================
# AgentHooks
# ============================================================================

@testset "AgentHooks defaults — all nothing" begin
    h = AgentHooks()
    @test h.on_turn_start === nothing
    @test h.on_turn_end === nothing
    @test h.on_tool_call === nothing
    @test h.on_tool_result === nothing
    @test h.should_interrupt === nothing
end

@testset "AgentHooks custom callbacks stored" begin
    fired = Dict{String,Any}()
    h = AgentHooks(
        on_turn_start = (msg, hist) -> (fired["turn_start"] = true),
        on_turn_end = (msg, hist) -> (fired["turn_end"] = true),
        on_tool_call = (name, args) -> (fired["tool_call"] = name),
        on_tool_result = (name, res) -> (fired["tool_result"] = name),
        should_interrupt = (name, args) -> name == "stop_me",
    )
    @test h.on_turn_start !== nothing
    @test h.on_tool_call !== nothing
    @test h.should_interrupt !== nothing

    h.on_tool_call("my_tool", Dict())
    @test fired["tool_call"] == "my_tool"

    h.on_tool_result("my_tool", "result text")
    @test fired["tool_result"] == "my_tool"

    @test h.should_interrupt("stop_me", Dict()) == true
    @test h.should_interrupt("allow_me", Dict()) == false
end

# ============================================================================
# Agent
# ============================================================================

@testset "Agent construction — defaults" begin
    p = OpenAIProvider(api_key = "test-key", model = "gpt-4o-mini")
    a = Agent(p)
    @test a.provider === p
    @test a.system_prompt == "You are a helpful assistant."
    @test a.workspace == "context"
    @test a.retry.max_retries == 3
    @test a.hooks.on_tool_call === nothing
    @test a.memory.enable == true
    @test a.builtin_tools.enable == true
    @test a.max_tool_iterations == 10
    @test a.mcp_servers == _Agent_MCPServer[]
end

@testset "Agent construction — custom values" begin
    p = OpenAIProvider(api_key = "k", model = "gpt-4o")
    r = RetryConfig(max_retries = 7, jitter = false)
    h = AgentHooks(on_tool_call = (n, a) -> nothing)
    a = Agent(p;
        system_prompt = "Be terse.",
        workspace = "myctx",
        hooks = h,
        retry = r,
        max_tool_iterations = 5,
        enable_memory = false,
        enable_cron = false,
    )
    @test a.system_prompt == "Be terse."
    @test a.workspace == "myctx"
    @test a.retry.max_retries == 7
    @test a.retry.jitter == false
    @test a.hooks.on_tool_call !== nothing
    @test a.max_tool_iterations == 5
    @test a.memory.enable == false
    @test a.enable_cron == false
end

@testset "Agent construction — function system_prompt" begin
    p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini")
    fn = (session_key) -> "Hello $session_key"
    a = Agent(p; system_prompt = fn)
    @test a.system_prompt === fn
end

@testset "Agent construction — allowed_tools coerced to Vector{String}" begin
    p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini")
    a = Agent(p; allowed_tools = ["read_file", "web_search"])
    @test a.allowed_tools == ["read_file", "web_search"]
    @test a.allowed_tools isa Vector{String}

    a2 = Agent(p; allowed_tools = nothing)
    @test a2.allowed_tools === nothing
end

# ============================================================================
# _retry_sleep — deterministic with jitter=false
# ============================================================================

const _AGENT_FAST = get(ENV, "KRILL_FAST_TESTS", "0") == "1"

if !_AGENT_FAST
    @testset "_retry_sleep with RetryConfig (no jitter)" begin
        r = RetryConfig(base_delay_s = 1.0, multiplier = 2.0, max_delay_s = 10.0, jitter = false)
        p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini")

        t1 = @elapsed _LLM._retry_sleep(1, r, p)  # 1.0 * 2^0 = 1.0
        t2 = @elapsed _LLM._retry_sleep(2, r, p)  # 1.0 * 2^1 = 2.0
        t3 = @elapsed _LLM._retry_sleep(5, r, p)  # clamped to 10.0

        @test t1 >= 0.9 && t1 < 1.5
        @test t2 >= 1.8 && t2 < 2.5
        @test t3 >= 9.5 && t3 < 11.0
    end

    @testset "_retry_sleep falls back to provider when retry_config=nothing" begin
        # provider has max_retries=2, retry_base=0.1 — fallback path
        p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini",
            max_retries = 2, retry_base_seconds = 0.1)
        t = @elapsed _LLM._retry_sleep(1, nothing, p)  # 0.1 * 2^0 = 0.1
        @test t >= 0.08 && t < 0.5
    end
end

# ============================================================================
# _post_json retry behaviour with RetryConfig
# ============================================================================

@testset "_post_json retries on retriable status codes from RetryConfig" begin
    attempt = Ref(0)
    mock_req =
        (method, url, headers, body) -> begin
            attempt[] += 1
            attempt[] < 3 ?
            HTTP.Response(429, "rate limited") :
            HTTP.Response(200, JSON3.write(Dict("id" => "r1", "output" => [], "usage" => Dict())))
        end

    p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini", request = mock_req,
        max_retries = 0)  # provider retries disabled — only RetryConfig active
    r = RetryConfig(max_retries = 3, base_delay_s = 0.01, max_delay_s = 0.1, jitter = false,
        retriable_status_codes = Set{Int}([429]))

    body = _LLM._post_json(p, "https://example.com", Dict{String,Any}();
        retry_config = r)
    @test attempt[] == 3
end

@testset "_post_json stops retrying on non-retriable status" begin
    attempt = Ref(0)
    mock_req = (method, url, headers, body) -> begin
        attempt[] += 1
        HTTP.Response(400, "bad request")
    end
    p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini", request = mock_req,
        max_retries = 0)
    r = RetryConfig(max_retries = 3, base_delay_s = 0.01, jitter = false,
        retriable_status_codes = Set{Int}([429, 500]))

    @test_throws _LLM.OpenAIAPIError _LLM._post_json(p, "https://example.com",
        Dict{String,Any}(); retry_config = r)
    @test attempt[] == 1  # no retry — 400 not in retriable set
end

@testset "_post_json status codes from RetryConfig override provider defaults" begin
    attempt = Ref(0)
    mock_req =
        (method, url, headers, body) -> begin
            attempt[] += 1
            attempt[] < 2 ?
            HTTP.Response(503, "unavailable") :
            HTTP.Response(200, JSON3.write(Dict("id" => "r1", "output" => [], "usage" => Dict())))
        end
    # Only 503 is retriable (not the default set)
    r = RetryConfig(max_retries = 2, base_delay_s = 0.01, jitter = false,
        retriable_status_codes = Set{Int}([503]))
    p = OpenAIProvider(api_key = "k", model = "gpt-4o-mini", request = mock_req,
        max_retries = 0)

    _LLM._post_json(p, "https://example.com", Dict{String,Any}(); retry_config = r)
    @test attempt[] == 2
end

# ============================================================================
# AgentHooks: on_tool_call / on_tool_result / should_interrupt
# via _execute_tool_calls
# ============================================================================

@testset "_execute_tool_calls fires on_tool_call and on_tool_result hooks" begin
    registry = ToolRegistry()
    register_tool!(
        registry,
        ToolDef(
            name = "echo",
            description = "echo the input",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict("text" => Dict("type" => "string")),
            ),
            execute = (args) -> get(args, "text", ""),
        ),
    )

    calls_seen = String[]
    results_seen = String[]
    h = AgentHooks(
        on_tool_call = (name, args) -> push!(calls_seen, name),
        on_tool_result = (name, res) -> push!(results_seen, name),
    )

    tool_calls = [_LLM.LLMToolCall("c1", "echo", Dict{String,Any}("text" => "hello"))]

    result = _LLM._execute_tool_calls(registry, tool_calls;
        max_tool_output_chars = 1000,
        hooks = h,
    )

    @test calls_seen == ["echo"]
    @test results_seen == ["echo"]
    @test result.interrupted == false
    @test length(result.events) == 1
end

@testset "_execute_tool_calls should_interrupt stops loop" begin
    registry = ToolRegistry()
    register_tool!(
        registry,
        ToolDef(
            name = "tool_a",
            description = "first",
            parameters = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
            execute = (_) -> "a done",
        ),
    )
    register_tool!(
        registry,
        ToolDef(
            name = "tool_b",
            description = "second",
            parameters = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
            execute = (_) -> "b done",
        ),
    )

    dispatched = String[]
    h = AgentHooks(
        on_tool_call = (name, args) -> push!(dispatched, name),
        should_interrupt = (name, args) -> name == "tool_b",  # stop before tool_b
    )

    tool_calls = [
        _LLM.LLMToolCall("c1", "tool_a", Dict{String,Any}()),
        _LLM.LLMToolCall("c2", "tool_b", Dict{String,Any}()),
    ]

    result = _LLM._execute_tool_calls(registry, tool_calls;
        max_tool_output_chars = 1000,
        hooks = h,
    )

    @test result.interrupted == true
    @test "tool_a" in dispatched          # tool_a ran before the interrupt check on tool_b
    @test !("tool_b" in dispatched)       # tool_b was never dispatched
end

@testset "_execute_tool_calls hook failures are swallowed" begin
    registry = ToolRegistry()
    register_tool!(
        registry,
        ToolDef(
            name = "noop",
            description = "does nothing",
            parameters = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
            execute = (_) -> "ok",
        ),
    )

    h = AgentHooks(
        on_tool_call = (name, args) -> error("hook exploded"),
        on_tool_result = (name, res) -> error("hook exploded too"),
    )

    tool_calls = [_LLM.LLMToolCall("c1", "noop", Dict{String,Any}())]

    # Should not throw despite both hooks raising
    result = _LLM._execute_tool_calls(registry, tool_calls;
        max_tool_output_chars = 1000,
        hooks = h,
    )
    @test length(result.events) == 1  # tool still ran
    @test result.interrupted == false
end
