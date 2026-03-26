module LLM

# API references used while implementing this module:
# - OpenAI Responses API: https://platform.openai.com/docs/api-reference/responses
# - OpenAI function calling (Responses): https://platform.openai.com/docs/guides/function-calling
# - Gemini native REST generateContent: https://ai.google.dev/api/rest/v1beta/models/generateContent
# - Gemini function calling guide: https://ai.google.dev/gemini-api/docs/function-calling
# - Gemini OpenAI compatibility: https://ai.google.dev/gemini-api/docs/openai
# - Gemini discovery schema (v1beta): https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta

using Base64
using HTTP
using JSON3

using ..Types:
    BinaryPart, ContentPart, ErrorEnvelope, InboundMessage, TextPart, ToolCallEvent, ToolResultEvent, message_text
using ..Sessions: TurnRecord
using ..Memory: MemoryStore, load_memory
using ..Tools: ToolRegistry, ToolDef, tools_schema, dispatch_tool, register_tool!, get_tool, tool_names

export AbstractLLMProvider,
    OpenAIProvider,
    GeminiProvider,
    GeminiOpenAICompatProvider,
    OpenAIAPIError,
    LLMToolCall,
    LLMUsage,
    LLMResponse,
    build_context,
    chat_completion,
    make_llm_processor

include("providers.jl")
include("api.jl")
include("context.jl")
include("parsing.jl")
include("chat_completion.jl")
include("tool_loop.jl")
include("processor.jl")

end
