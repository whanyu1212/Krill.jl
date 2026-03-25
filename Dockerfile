# ── Stage 1: dependency precompile ────────────────────────────────────────────
FROM julia:1.12.4-bookworm AS deps

WORKDIR /app

# Copy only the manifest files first — layer is cached until deps change
COPY Project.toml Manifest.toml ./

RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM julia:1.12.4-bookworm

WORKDIR /app

# Reuse precompiled depot from stage 1
COPY --from=deps /root/.julia /root/.julia
COPY --from=deps /app /app

# Copy source and entrypoint
COPY src/ src/
COPY bin/ bin/
COPY context/ context/
COPY krill.toml.example krill.toml.example

# Precompile Krill itself (not just deps) — reduces first-request latency
RUN julia --project=. -e 'using Krill'

# Cloud Run injects PORT env var; Krill reads it for the webhook listener
ENV PORT=8080

# krill.toml is NOT baked in — mount it or supply secrets via env vars
# data_dir is mounted from GCS at /data at runtime
CMD ["julia", "--project=.", "--threads=auto", "bin/krill.jl"]
