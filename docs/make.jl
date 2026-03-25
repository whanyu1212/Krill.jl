using Documenter, DocumenterVitepress
using Krill

makedocs(;
    modules = [Krill],
    authors = "hanyuwu and contributors",
    repo = "https://github.com/whanyu1212/Krill.jl/blob/{commit}{path}#{line}",
    sitename = "Krill.jl",
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "https://github.com/whanyu1212/Krill.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    draft = false,
    checkdocs = :none,
    warnonly = [:cross_references],
    source = "src",
    build = "build",
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Getting Started" => "guide/getting_started.md",
            "Configuration" => "guide/configuration.md",
            "Architecture" => "guide/architecture.md",
            "Features" => "guide/features.md",
            "Security" => "guide/security.md",
            "Deployment" => "guide/deployment.md",
        ],
        "Examples" => [
            "Runnable Example" => "examples/telegram.md",
            "Use Case Testing" => "examples/use_cases.md",
        ],
        "Reference" => "api/reference.md",
        "Roadmap" => "notes/roadmap.md",
    ],
)

# Documenter processes index.md through its Markdown AST pipeline, which
# collapses YAML frontmatter and HTML-escapes SVG icons — breaking the
# VitePress home page layout. Restore the original file after makedocs runs.
cp(
    joinpath(@__DIR__, "src", "index.md"),
    joinpath(@__DIR__, "build", ".documenter", "index.md");
    force = true,
)

# Post-process built Markdown to fix Documenter AST artifacts:
#  1. Collapsed VitePress containers (::: warning ... ::: on one line)
#  2. Runs of 3+ newlines (Documenter inserts extra blank lines)
#  3. Blank lines between consecutive fenced code blocks
#     (created by #2's fix — must run last)
function postprocess_markdown(builddir)
    nfixed = 0
    for (root, _, files) in walkdir(builddir)
        for f in files
            endswith(f, ".md") || continue
            path = joinpath(root, f)
            content = read(path, String)
            orig = content

            # Restore collapsed ::: containers
            content = replace(content,
                r"^(::: ?\w+)(?: ([^\n]*?))? (:::)$"m =>
                    function(m)
                        m_match = match(r"^(::: ?\w+)(?: ([^\n]*?))? (:::)$", m)
                        opener = m_match[1]
                        body = m_match[2]
                        body === nothing && return m
                        return string(opener, "\n", body, "\n:::")
                    end
            )

            # Collapse runs of 3+ newlines down to 2 (single blank line)
            content = replace(content, r"\n{3,}" => "\n\n")

            # Remove blank lines between consecutive fenced code blocks
            # (must run AFTER collapsing triple newlines, which creates these)
            while occursin(r"```\n\n```", content)
                content = replace(content, r"```\n\n```" => "```\n```")
            end

            if content != orig
                nfixed += 1
                write(path, content)
            end
        end
    end
    @info "Post-processed $nfixed Markdown files in $builddir"
end

let builddir = joinpath(@__DIR__, "build", ".documenter")
    postprocess_markdown(builddir)
end

# Rebuild VitePress from the post-processed Markdown.
run(Cmd(`npm run docs:build`; dir=@__DIR__))
