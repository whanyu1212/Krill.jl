# ── Stage 1: dependency install ───────────────────────────────────────────────
FROM julia:1.12.4-bookworm AS deps

WORKDIR /app

COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM julia:1.12.4-bookworm

# Node.js — needed for MCP stdio servers (npx)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Reuse deps from stage 1
COPY --from=deps /root/.julia /root/.julia
COPY --from=deps /app /app

# Copy source and entrypoint
COPY src/ src/
COPY bin/ bin/
COPY context/ context/
COPY krill.toml krill.toml

# Precompile Krill and warm up hot code paths
RUN julia --project=. -e ' \
    using Krill; \
    using HTTP; \
    using JSON3; \
    try; load_config(config_path="krill.toml", project_root="."); catch _; end; \
    '

ENV PORT=8080

CMD ["julia", "--project=.", "--threads=auto", "bin/krill.jl"]
