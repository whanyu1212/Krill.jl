using Krill
using Krill: SkillDef, discover_skills, read_skill, skills_summary, load_always_skills,
    compose_instructions, make_prompt_builder, BootstrapDoc, InboundMessage
using Test

# ============================================================================
# Helpers
# ============================================================================

function make_skill_workspace(; skills = Dict{String,String}(), builtin = Dict{String,String}())
    dir = mktempdir()
    ws = joinpath(dir, "workspace")
    mkpath(joinpath(ws, "skills"))

    for (name, content) in skills
        skill_dir = joinpath(ws, "skills", name)
        mkpath(skill_dir)
        write(joinpath(skill_dir, "SKILL.md"), content)
    end

    builtin_dir = nothing
    if !isempty(builtin)
        builtin_dir = joinpath(dir, "builtin")
        mkpath(builtin_dir)
        for (name, content) in builtin
            skill_dir = joinpath(builtin_dir, name)
            mkpath(skill_dir)
            write(joinpath(skill_dir, "SKILL.md"), content)
        end
    end

    return ws, builtin_dir
end

function make_test_msg(; channel = :test, session_key = "s", chat_id = "c", user_id = "u")
    return InboundMessage(
        channel = channel,
        session_key = session_key,
        chat_id = chat_id,
        user_id = user_id,
        text = "hi",
    )
end

# ============================================================================
# SkillDef construction
# ============================================================================

@testset "SkillDef construction" begin
    @testset "full constructor" begin
        s = SkillDef("test", "A test skill", "/path", "workspace", true, true, String[])
        @test s.name == "test"
        @test s.always == true
        @test s.available == true
        @test isempty(s.missing_requirements)
    end

    @testset "backward-compatible constructor" begin
        s = SkillDef("test", "A test skill", "/path", "workspace")
        @test s.always == false
        @test s.available == true
        @test isempty(s.missing_requirements)
    end
end

# ============================================================================
# Frontmatter parsing and always flag
# ============================================================================

@testset "Always-on skill discovery" begin
    @testset "discovers always: true from frontmatter" begin
        ws, _ = make_skill_workspace(skills = Dict(
            "auto-skill" => """---
description: Auto-loaded skill
always: true
---
This skill is always loaded.""",
            "normal-skill" => """---
description: Normal skill
---
This skill is loaded on demand.""",
        ))

        skills = discover_skills(ws)
        @test length(skills) == 2

        auto = only(filter(s -> s.name == "auto-skill", skills))
        @test auto.always == true
        @test auto.available == true
        @test auto.description == "Auto-loaded skill"

        normal = only(filter(s -> s.name == "normal-skill", skills))
        @test normal.always == false
    end

    @testset "always accepts yes/1/true" begin
        for val in ["true", "yes", "1", "True", "YES"]
            ws, _ = make_skill_workspace(skills = Dict(
                "s" => "---\ndescription: test\nalways: $val\n---\nContent",
            ))
            skills = discover_skills(ws)
            @test length(skills) == 1
            @test skills[1].always == true
        end
    end

    @testset "always defaults to false" begin
        for val in ["false", "no", "0", ""]
            ws, _ = make_skill_workspace(skills = Dict(
                "s" => "---\ndescription: test\nalways: $val\n---\nContent",
            ))
            skills = discover_skills(ws)
            @test skills[1].always == false
        end
    end

    @testset "no frontmatter means always=false" begin
        ws, _ = make_skill_workspace(skills = Dict(
            "bare" => "Just some instructions without frontmatter.",
        ))
        skills = discover_skills(ws)
        @test length(skills) == 1
        @test skills[1].always == false
        @test skills[1].available == true
    end
end

# ============================================================================
# Requirement checking
# ============================================================================

@testset "Requirement checking" begin
    @testset "requires_bins with available binary" begin
        ws, _ = make_skill_workspace(skills = Dict(
            "s" => "---\ndescription: test\nrequires_bins: julia\n---\nContent",
        ))
        skills = discover_skills(ws)
        @test skills[1].available == true
        @test isempty(skills[1].missing_requirements)
    end

    @testset "requires_bins with missing binary" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "s" => "---\ndescription: test\nrequires_bins: nonexistent_binary_xyz_999\n---\nContent",
            ),
        )
        skills = discover_skills(ws)
        @test skills[1].available == false
        @test !isempty(skills[1].missing_requirements)
        @test any(contains(r, "nonexistent_binary_xyz_999") for r in skills[1].missing_requirements)
    end

    @testset "requires_bins with multiple binaries" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "s" => "---\ndescription: test\nrequires_bins: julia, nonexistent_xyz\n---\nContent",
            ),
        )
        skills = discover_skills(ws)
        @test skills[1].available == false
        @test length(skills[1].missing_requirements) == 1  # only nonexistent is missing
    end

    @testset "requires_env with present var" begin
        ENV["_KRILL_TEST_SKILL_VAR"] = "1"
        try
            ws, _ = make_skill_workspace(
                skills = Dict(
                    "s" => "---\ndescription: test\nrequires_env: _KRILL_TEST_SKILL_VAR\n---\nContent",
                ),
            )
            skills = discover_skills(ws)
            @test skills[1].available == true
        finally
            delete!(ENV, "_KRILL_TEST_SKILL_VAR")
        end
    end

    @testset "requires_env with missing var" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "s" => "---\ndescription: test\nrequires_env: _KRILL_NONEXISTENT_VAR_XYZ\n---\nContent",
            ),
        )
        skills = discover_skills(ws)
        @test skills[1].available == false
        @test any(contains(r, "_KRILL_NONEXISTENT_VAR_XYZ") for r in skills[1].missing_requirements)
    end

    @testset "combined bins and env requirements" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "s" => "---\ndescription: test\nrequires_bins: nonexistent_bin_abc\nrequires_env: _KRILL_NONEXISTENT_VAR\n---\nContent",
            ),
        )
        skills = discover_skills(ws)
        @test skills[1].available == false
        @test length(skills[1].missing_requirements) == 2
    end

    @testset "no requirements means available" begin
        ws, _ = make_skill_workspace(skills = Dict(
            "s" => "---\ndescription: test\n---\nContent",
        ))
        skills = discover_skills(ws)
        @test skills[1].available == true
    end
end

# ============================================================================
# skills_summary with availability markers
# ============================================================================

@testset "skills_summary with markers" begin
    @testset "always-on skills show marker" begin
        skills = [
            SkillDef("auto", "Auto skill", "/p", "workspace", true, true, String[]),
            SkillDef("normal", "Normal skill", "/p", "workspace", false, true, String[]),
        ]
        summary = skills_summary(skills)
        @test contains(summary, "[always-on]")
        @test contains(summary, "**auto**")
        @test !contains(summary, "normal] [always-on]")  # normal shouldn't have marker
    end

    @testset "unavailable skills show requirements" begin
        skills = [
            SkillDef("broken", "Broken skill", "/p", "workspace", false, false, ["bin: foo", "env: BAR"]),
        ]
        summary = skills_summary(skills)
        @test contains(summary, "[unavailable:")
        @test contains(summary, "bin: foo")
        @test contains(summary, "env: BAR")
    end

    @testset "available non-always skills have no marker" begin
        skills = [
            SkillDef("plain", "Plain skill", "/p", "workspace", false, true, String[]),
        ]
        summary = skills_summary(skills)
        @test contains(summary, "**plain**: Plain skill")
        @test !contains(summary, "[")
    end
end

# ============================================================================
# load_always_skills
# ============================================================================

@testset "load_always_skills" begin
    @testset "loads always-on available skills" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "auto" => "---\ndescription: Auto\nalways: true\n---\n# Auto Instructions\n\nDo this automatically.",
                "manual" => "---\ndescription: Manual\n---\n# Manual Instructions\n\nDo this on demand.",
            ),
        )
        skills = discover_skills(ws)
        result = load_always_skills(skills)
        @test result !== nothing
        @test contains(result, "Active Skills")
        @test contains(result, "Skill: auto")
        @test contains(result, "Do this automatically.")
        @test !contains(result, "Manual")
        # Frontmatter should be stripped
        @test !contains(result, "always: true")
    end

    @testset "returns nothing when no always-on skills" begin
        ws, _ = make_skill_workspace(skills = Dict(
            "manual" => "---\ndescription: Manual\n---\nContent",
        ))
        skills = discover_skills(ws)
        @test load_always_skills(skills) === nothing
    end

    @testset "skips unavailable always-on skills" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "broken-auto" => "---\ndescription: Broken\nalways: true\nrequires_bins: nonexistent_xyz_999\n---\nShould not appear.",
            ),
        )
        skills = discover_skills(ws)
        @test skills[1].always == true
        @test skills[1].available == false
        @test load_always_skills(skills) === nothing
    end

    @testset "loads multiple always-on skills" begin
        ws, _ = make_skill_workspace(
            skills = Dict(
                "auto-a" => "---\ndescription: A\nalways: true\n---\nContent A",
                "auto-b" => "---\ndescription: B\nalways: true\n---\nContent B",
                "manual" => "---\ndescription: M\n---\nContent M",
            ),
        )
        skills = discover_skills(ws)
        result = load_always_skills(skills)
        @test result !== nothing
        @test contains(result, "Skill: auto-a")
        @test contains(result, "Skill: auto-b")
        @test contains(result, "Content A")
        @test contains(result, "Content B")
        @test !contains(result, "Content M")
    end

    @testset "builtin always-on skills work" begin
        ws, builtin = make_skill_workspace(
            builtin = Dict(
                "builtin-auto" => "---\ndescription: Builtin auto\nalways: true\n---\nBuiltin always content.",
            ),
        )
        skills = discover_skills(ws; builtin_skills_dir = builtin)
        result = load_always_skills(skills)
        @test result !== nothing
        @test contains(result, "Builtin always content.")
    end
end

# ============================================================================
# compose_instructions with always_skills_text
# ============================================================================

@testset "compose_instructions with always skills" begin
    @testset "includes always_skills_text" begin
        result = compose_instructions("Base prompt";
            always_skills_text = "## Active Skills\n\n### Skill: auto\n\nDo this.",
        )
        @test result !== nothing
        @test contains(result, "Base prompt")
        @test contains(result, "Active Skills")
        @test contains(result, "Do this.")
    end

    @testset "nothing always_skills_text is skipped" begin
        result = compose_instructions("Base prompt";
            always_skills_text = nothing,
        )
        @test result == "Base prompt"
    end

    @testset "empty always_skills_text is skipped" begin
        result = compose_instructions("Base prompt";
            always_skills_text = "  ",
        )
        @test result == "Base prompt"
    end

    @testset "always skills appear between skills summary and memory" begin
        result = compose_instructions("Base";
            skills_summary_text = "## Skills Summary",
            always_skills_text = "## Active Skills",
            memory_text = "Memory content",
        )
        @test result !== nothing
        # Check ordering: skills summary before always before memory
        idx_summary = findfirst("Skills Summary", result)
        idx_always = findfirst("Active Skills", result)
        idx_memory = findfirst("Memory content", result)
        @test idx_summary !== nothing
        @test idx_always !== nothing
        @test idx_memory !== nothing
        @test first(idx_summary) < first(idx_always) < first(idx_memory)
    end
end

# ============================================================================
# make_prompt_builder with always skills
# ============================================================================

@testset "make_prompt_builder with always skills" begin
    @testset "includes always skills in built prompt" begin
        builder = make_prompt_builder(
            skills_summary_text = "## Skills\n- auto: Auto skill [always-on]",
            always_skills_text = "## Active Skills\n\n### Skill: auto\n\nAuto instructions here.",
            include_runtime_metadata = false,
            include_tool_safety = false,
        )
        msg = make_test_msg()
        result = builder(msg, "System prompt")
        @test result !== nothing
        @test contains(result, "System prompt")
        @test contains(result, "Auto instructions here.")
    end

    @testset "nothing always skills works" begin
        builder = make_prompt_builder(
            always_skills_text = nothing,
            include_runtime_metadata = false,
            include_tool_safety = false,
        )
        msg = make_test_msg()
        result = builder(msg, "System prompt")
        @test result == "System prompt"
    end
end

# ============================================================================
# Workspace override of builtin always flag
# ============================================================================

@testset "Workspace overrides builtin" begin
    @testset "workspace skill overrides builtin with same name" begin
        ws, builtin = make_skill_workspace(
            skills = Dict(
                "shared" => "---\ndescription: Workspace version\nalways: false\n---\nWorkspace content.",
            ),
            builtin = Dict(
                "shared" => "---\ndescription: Builtin version\nalways: true\n---\nBuiltin content.",
            ),
        )
        skills = discover_skills(ws; builtin_skills_dir = builtin)
        @test length(skills) == 1
        shared = skills[1]
        @test shared.source == "workspace"
        @test shared.always == false  # workspace overrides builtin's always=true
    end
end
