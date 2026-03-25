# ── Stage 1: build sysimage with PackageCompiler ─────────────────────────────
FROM julia:1.12.4-bookworm AS builder

# Node.js — needed for MCP stdio servers (npx) during precompile
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps first (cached layer)
COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Install PackageCompiler into the project (build-time only — not in committed Manifest)
RUN julia --project=. -e 'using Pkg; Pkg.add("PackageCompiler")'

# Copy source
COPY src/ src/
COPY bin/ bin/
COPY context/ context/
COPY krill.toml krill.toml
COPY scripts/build_sysimage.jl scripts/build_sysimage.jl
COPY scripts/precompile_workload.jl scripts/precompile_workload.jl

# Build the sysimage — this is the slow step (~5-10 min)
RUN mkdir -p build && \
    julia --project=. scripts/build_sysimage.jl

# ── Stage 2: slim runtime image ──────────────────────────────────────────────
FROM julia:1.12.4-bookworm

# Node.js — needed for MCP stdio servers (npx)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy sysimage, source, and deps from builder
COPY --from=builder /root/.julia /root/.julia
COPY --from=builder /app/build/krill.so /app/build/krill.so
COPY --from=builder /app/Project.toml /app/Manifest.toml ./
COPY --from=builder /app/src/ src/
COPY --from=builder /app/bin/ bin/
COPY --from=builder /app/context/ context/
COPY --from=builder /app/krill.toml krill.toml

ENV PORT=8080

# Use the sysimage — zero JIT at runtime
CMD ["julia", "--project=.", "--threads=auto", "--sysimage=build/krill.so", "bin/krill.jl"]
