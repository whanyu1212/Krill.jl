# Single-stage build with PackageCompiler sysimage
FROM julia:1.12.4-bookworm

# Build tools (gcc for PackageCompiler) + Node.js (for MCP stdio servers)
RUN apt-get update && \
    apt-get install -y gcc && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps
COPY Project.toml Manifest.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Install PackageCompiler (build-time only)
RUN julia --project=. -e 'using Pkg; Pkg.add("PackageCompiler")'

# Copy source
COPY src/ src/
COPY bin/ bin/
COPY context/ context/
COPY krill.toml krill.toml
COPY scripts/build_sysimage.jl scripts/build_sysimage.jl
COPY scripts/precompile_workload.jl scripts/precompile_workload.jl

# Build the sysimage (~5-10 min)
RUN mkdir -p build && \
    julia --project=. scripts/build_sysimage.jl

ENV PORT=8080

# Use the sysimage — zero JIT at runtime
CMD ["julia", "--project=.", "--threads=auto", "--sysimage=build/krill.so", "bin/krill.jl"]
