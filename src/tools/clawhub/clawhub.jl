module ClawHub

using HTTP
using JSON3
using Dates
using SHA

using ..Tools: ToolDef, ToolRegistry, register_tool!
using ..Skills

export ClawHubClient,
    SkillStore, SkillManifestEntry,
    ValidationPolicy, ValidationResult,
    clawhub_search, clawhub_skill_info, clawhub_download,
    manifest_path, quarantine_dir, verified_dir, verified_root,
    load_manifest!, save_manifest!,
    add_quarantined!, promote!, reject!, remove!,
    get_entry, list_entries, has_skill,
    validate_skill, default_policy,
    register_clawhub_tools!

include("client.jl")
include("store.jl")
include("validation.jl")
include("tools.jl")

end
