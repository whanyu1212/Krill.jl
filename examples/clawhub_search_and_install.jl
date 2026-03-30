# ClawHub: Search, Validate, and Install a Skill
#
# This example shows how to use the ClawHub integration programmatically
# to search the public skill registry, inspect results, and install a
# skill through the quarantine → validation → verified store pipeline.
#
# It also demonstrates the trust-boundary behaviour applied to verified
# ClawHub skills in the agent runtime:
#
#   1. Skills summary — description is masked; only a static
#      "(third-party, on-demand) [source: clawhub]" marker appears.
#   2. Always-on injection — `always: true` in ClawHub frontmatter is
#      silently ignored; bodies are never auto-injected into the system prompt.
#   3. read_skill — the returned body is wrapped in an explicit
#      untrusted-content frame so the LLM treats it as reference material,
#      not as instructions.
#
# The same flow happens automatically when the agent calls the
# `clawhub_search` and `clawhub_install` tools during a conversation.
#
# Usage:
#   julia --project=. examples/clawhub_search_and_install.jl "web scraping"

using Krill
using Krill: ClawHubClient, SkillStore, SkillManifestEntry,
    ValidationPolicy, ValidationResult,
    clawhub_search, clawhub_skill_info, clawhub_download,
    validate_skill, default_policy,
    discover_skills, skills_summary, load_always_skills, register_read_skill_tool!,
    ToolRegistry, get_tool,
    verified_root

# ── Configuration ─────────────────────────────────────────────────────

const DATA_DIR = get(ENV, "KRILL_DATA_DIR", joinpath(homedir(), ".krill"))
const CLAWHUB_URL = get(ENV, "CLAWHUB_API_URL", "https://clawhub.ai/api/v1")
const CLAWHUB_TOKEN = get(ENV, "CLAWHUB_TOKEN", "")  # optional

# ── Setup ─────────────────────────────────────────────────────────────

client = ClawHubClient(
    base_url = CLAWHUB_URL,
    auth_token = isempty(CLAWHUB_TOKEN) ? nothing : CLAWHUB_TOKEN,
)

store = SkillStore(; data_dir = DATA_DIR)

# Validation policy — tune these for your risk tolerance
policy = ValidationPolicy(
    content_scan = true,       # scan for dangerous patterns (run(), ENV[], @eval, etc.)
    metadata_check = true,     # require SKILL.md with description
    min_downloads = 10,        # reject skills with fewer than 10 downloads
    min_stars = 0,             # no star requirement
    blocked_slugs = Set(["known-malicious-skill"]),
    blocked_authors = Set{String}(),
)

# ── Step 1: Search ────────────────────────────────────────────────────

query = length(ARGS) >= 1 ? ARGS[1] : "web scraping"
println("🔍 Searching ClawHub for: \"$(query)\"\n")

results = clawhub_search(client, query; limit = 5)

if isempty(results)
    println("No skills found.")
    exit(0)
end

for (i, skill) in enumerate(results)
    slug = get(skill, "slug", get(skill, "name", "?"))
    name = get(skill, "name", slug)
    desc = get(skill, "description", "")
    author = get(skill, "author", "")
    downloads = get(skill, "downloads", 0)
    stars = get(skill, "stars", 0)
    println("  $(i). $(name) ($(slug))")
    !isempty(desc) && println("     $(desc)")
    println("     by $(author) · $(downloads) downloads · $(stars) stars")
    println()
end

# ── Step 2: Pick the first result and inspect ─────────────────────────

slug = get(results[1], "slug", get(results[1], "name", ""))
println("📦 Inspecting: $(slug)\n")

info = clawhub_skill_info(client, slug)
for key in ("name", "description", "author", "version", "downloads", "stars")
    val = get(info, key, nothing)
    val === nothing && continue
    println("  $(key): $(val)")
end
println()

# ── Step 3: Download to quarantine ────────────────────────────────────

println("⬇️  Downloading to quarantine...")

q_dir = Krill.ClawHub.quarantine_dir(store, slug)
rm(q_dir; force = true, recursive = true)
mkpath(q_dir)

version = String(get(info, "version", get(info, :version, "latest")))
sha256_hash = clawhub_download(client, slug, version, q_dir)
println("  SHA256: $(sha256_hash)")
println("  Quarantine dir: $(q_dir)\n")

# Register in manifest
entry = SkillManifestEntry(
    slug = slug,
    version = version,
    sha256 = sha256_hash,
    source_url = "$(CLAWHUB_URL)/download/$(slug)/$(version)",
    author = String(get(info, "author", "")),
    downloads = Int(get(info, "downloads", 0)),
    stars = Int(get(info, "stars", 0)),
)
Krill.ClawHub.add_quarantined!(store, entry)

# ── Step 4: Validate ──────────────────────────────────────────────────

println("🔒 Running validation gate...")

result = validate_skill(q_dir, policy; remote_meta = info)

if result.passed
    println("  ✅ Validation PASSED\n")

    # ── Step 5: Promote to verified store ─────────────────────────────
    println("📥 Promoting to verified store...")
    Krill.ClawHub.promote!(store, slug)

    v_dir = Krill.ClawHub.verified_dir(store, slug)
    println("  Verified dir: $(v_dir)")
    println("  Skill is now available via `read_skill` in the agent runtime.\n")

    # Show the installed SKILL.md
    skill_file = joinpath(v_dir, "SKILL.md")
    if isfile(skill_file)
        content = read(skill_file, String)
        println("─── SKILL.md ───────────────────────────────────────")
        println(first(content, 500))
        length(content) > 500 && println("... ($(length(content)) chars total)")
        println("────────────────────────────────────────────────────")
    end

    # ── Step 6: Show trust-boundary behaviour ─────────────────────────
    #
    # Verified ClawHub skills are subject to three prompt-injection
    # hardening rules. This block demonstrates each one so you can see
    # exactly what the agent runtime sees.

    println("\n🔐 Trust-boundary demonstration\n")

    # Use a minimal workspace with no local skills so the ClawHub skill
    # is the only one discovered.
    tmp_ws = mktempdir()
    mkpath(joinpath(tmp_ws, "skills"))

    discovered = discover_skills(tmp_ws; clawhub_skills_dir = verified_root(store))

    # ── 6a: Skills summary ────────────────────────────────────────────
    println("6a. Skills summary (what appears in the system prompt):")
    println()
    println(skills_summary(discovered))
    println()
    println("  ↳ The ClawHub skill's description is NOT shown.")
    println("    Only the static '(third-party, on-demand) [source: clawhub]'")
    println("    marker appears, regardless of what the skill author wrote.")
    println()

    # ── 6b: Always-on injection ───────────────────────────────────────
    println("6b. Always-on injection check:")
    always_text = load_always_skills(discovered)
    if always_text === nothing
        println("  load_always_skills → nothing")
        println("  ↳ No ClawHub skill body was auto-injected, even if the skill")
        println("    declares 'always: true' in its frontmatter.")
    else
        # Should not happen — shown here for completeness
        println("  load_always_skills returned content (unexpected for ClawHub skills):")
        println(always_text)
    end
    println()

    # ── 6c: read_skill wrapping ───────────────────────────────────────
    println("6c. read_skill result (what the LLM receives on demand):")
    println()
    registry = ToolRegistry()
    register_read_skill_tool!(
        registry;
        workspace = tmp_ws,
        clawhub_skills_dir = verified_root(store),
        skills = discovered,
    )
    read_skill_tool = get_tool(registry, "read_skill")
    wrapped = read_skill_tool.execute(Dict{String,Any}("name" => slug))
    println(wrapped)
    println()
    println("  ↳ The body is present for reference, but bracketed by explicit")
    println("    untrusted-content markers so the LLM cannot mistake it for")
    println("    authoritative instructions.")
else
    println("  ❌ Validation FAILED:")
    for reason in result.reasons
        println("     - $(reason)")
    end
    println()

    # Reject and clean up
    Krill.ClawHub.reject!(store, slug)
    println("  Skill rejected and quarantine cleaned up.")
end

# ── Final state ───────────────────────────────────────────────────────

println("\n📋 Current skill store:")
entries = Krill.ClawHub.list_entries(store)
if isempty(entries)
    println("  (empty)")
else
    for e in entries
        marker = e.status == "verified" ? "✅" : e.status == "rejected" ? "❌" : "⏳"
        println("  $(marker) $(e.slug) v$(e.version) [$(e.status)]")
    end
end
