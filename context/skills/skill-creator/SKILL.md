---
name: skill-creator
description: "Create or update skills for the Krill agent. Use when designing, structuring, or writing new skills, or when improving existing ones. Covers skill anatomy, frontmatter, bundled resources, and design principles."
---

# Skill Creator

Guide for creating effective skills that extend the Krill agent's capabilities.

## What Skills Are

Skills are modular, self-contained packages that provide the agent with specialized knowledge, workflows, and tools for specific domains. They transform a general-purpose agent into a specialized one by supplying procedural knowledge that no model fully possesses.

Skills provide:
1. **Specialized workflows** — multi-step procedures for specific domains
2. **Tool integration guidance** — how to use tools for specific tasks
3. **Domain expertise** — schemas, business logic, API patterns
4. **Bundled resources** — scripts, references, and assets for complex tasks

## Skill Location

Skills live in the workspace `skills/` directory:
```
context/skills/<skill-name>/SKILL.md
```

Krill discovers skills automatically at startup by scanning `{workspace}/skills/*/SKILL.md`.

## Anatomy of a Skill

```
skill-name/
├── SKILL.md              (required)
│   ├── YAML frontmatter  (required: name, description)
│   └── Markdown body     (instructions)
└── resources/            (optional)
    ├── scripts/          — executable code
    ├── references/       — docs loaded into context as needed
    └── assets/           — files used in output (templates, etc.)
```

### SKILL.md Frontmatter

Required fields:
```yaml
---
name: my-skill
description: "What this skill does and when to use it. Be specific — this is the primary trigger."
---
```

Optional fields:
```yaml
requires_bins: gh, curl        # comma-separated binaries that must be in PATH
requires_env: API_KEY, TOKEN   # comma-separated env vars that must be set
always: true                   # auto-inject full content into every system prompt
```

**Frontmatter rules:**
- `name` — the skill directory name, lowercase with hyphens.
- `description` — the most important field. This is what the agent reads to decide whether to load the skill. Include both what it does AND when to trigger it. The body is only loaded after triggering, so "When to Use" sections in the body don't help.
- `requires_bins` / `requires_env` — if requirements aren't met, the skill shows as `[unavailable]` but is still listed.
- `always: true` — use sparingly. Always-on skills consume context in every conversation. Only use for skills that are relevant to nearly every interaction (e.g., memory).

### Body (Markdown)

The instructions the agent follows after the skill is loaded via `read_skill`. Write in imperative form.

### Bundled Resources

#### Scripts (`scripts/`)
Executable code for tasks that need deterministic reliability or are repeatedly rewritten.
- When to include: same code gets rewritten each time, or deterministic output is needed.
- Benefits: token efficient, deterministic, can be executed without loading into context.

#### References (`references/`)
Documentation loaded into context as needed.
- When to include: detailed reference material the agent should consult while working.
- Examples: API docs, database schemas, company policies, domain knowledge.
- Best practice: if >10k words, include grep patterns in SKILL.md so the agent can search instead of reading fully.

#### Assets (`assets/`)
Files used in output, not loaded into context.
- When to include: templates, images, boilerplate code that gets copied or modified.
- Examples: HTML templates, config file templates, brand assets.

## Core Principles

### Concise is Key

The context window is shared. Challenge each piece of information: "Does the agent already know this?" and "Does this paragraph justify its token cost?"

Default assumption: the agent is already smart. Only add context it doesn't already have. Prefer concise examples over verbose explanations.

### Degrees of Freedom

Match specificity to how fragile the task is:

- **High freedom** (text instructions): multiple approaches are valid, context-dependent decisions.
- **Medium freedom** (pseudocode/parameterized scripts): a preferred pattern exists, some variation OK.
- **Low freedom** (exact scripts, few parameters): fragile operations, consistency critical.

### Progressive Disclosure

Skills use a three-level loading system:

1. **Metadata** (name + description) — always in context (~100 words)
2. **SKILL.md body** — loaded when skill triggers (target <500 lines)
3. **Bundled resources** — loaded only when the agent needs them

Keep SKILL.md body to essentials. Split into reference files when approaching 500 lines. Always reference split-out files from SKILL.md so the agent knows they exist.

**Pattern: High-level guide with references**
```markdown
# PDF Processing
## Quick start
[code example]
## Advanced
- Form filling: see references/forms.md
- API reference: see references/api.md
```

**Pattern: Domain-specific organization**
```
bigquery-skill/
├── SKILL.md (overview + navigation)
└── references/
    ├── finance.md
    ├── sales.md
    └── product.md
```
The agent only loads the relevant reference file.

## Creating a Skill

### Step 1: Understand with Examples

Clarify how the skill will be used. Ask:
- What should this skill help with?
- What would a user say that should trigger it?
- Can you give concrete examples of usage?

### Step 2: Plan Reusable Contents

For each example, consider:
1. How would I execute this from scratch?
2. What scripts, references, or assets would help if I did this repeatedly?

### Step 3: Create the Skill Directory

```bash
mkdir -p context/skills/<skill-name>
```

Create `SKILL.md` with frontmatter and body. Create resource subdirectories only if needed.

### Step 4: Write the Skill

Write SKILL.md and implement any bundled resources.

**Frontmatter:**
- Write a comprehensive `description` that covers what the skill does AND all trigger contexts.

**Body:**
- Write for another agent instance. Include non-obvious procedural knowledge.
- Use imperative form.
- Include examples mapped to the agent's actual tools (`exec`, `github`, `web_fetch`, etc.).
- Reference any bundled resource files and describe when to read them.

**Scripts:**
- Test scripts by actually running them to verify they work.

### Step 5: Verify

After creating the skill, verify:
1. The skill directory is at `context/skills/<name>/SKILL.md`.
2. Frontmatter has `name` and `description`.
3. Description is specific enough to trigger correctly.
4. Body references any resource files.
5. No extraneous files (no README.md, CHANGELOG.md, etc.).

### Step 6: Iterate

Use the skill on real tasks, notice struggles, update SKILL.md or resources, test again.

## Naming Rules

- Lowercase letters, digits, and hyphens only.
- Under 64 characters.
- Prefer short, verb-led phrases: `rotate-pdf`, `check-ci`, `deploy-app`.
- Namespace by tool when it improves clarity: `gh-review-pr`, `docker-compose-up`.
- The skill folder name must match the `name` field.

## What NOT to Include

- README.md, INSTALLATION_GUIDE.md, CHANGELOG.md, or any documentation not for the agent.
- "When to use this skill" sections in the body (put this in the description).
- Information the agent already knows (common programming patterns, well-known APIs).
- Setup/testing procedures, user-facing docs.
