# scripts/build_sysimage.jl
#
# Build an AOT-compiled sysimage for Krill using PackageCompiler.
# Run from the project root:
#   julia --project=. scripts/build_sysimage.jl
#
# The sysimage is written to build/krill.so

using PackageCompiler

create_sysimage(
    [:Krill, :HTTP, :JSON3];
    sysimage_path = joinpath(@__DIR__, "..", "build", "krill.so"),
    project = joinpath(@__DIR__, ".."),
    precompile_execution_file = joinpath(@__DIR__, "precompile_workload.jl"),
)
