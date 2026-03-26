using Krill
using Test
using Sockets

const _check_exec_denylist = Krill.BuiltinTools._check_exec_denylist
const _check_exec_urls = Krill.BuiltinTools._check_exec_urls
const _is_forbidden_ip = Krill.BuiltinTools._is_forbidden_ip
const _validate_http_url = Krill.BuiltinTools._validate_http_url
const _resolve_path = Krill.BuiltinTools._resolve_path

@testset "Exec command denylist" begin
    @testset "blocks rm -rf variants" begin
        @test _check_exec_denylist("rm -rf /") !== nothing
        @test _check_exec_denylist("rm -rf ~") !== nothing
        @test _check_exec_denylist("rm -fr /tmp/foo") !== nothing
        @test _check_exec_denylist("sudo rm -rf /var") !== nothing
    end

    @testset "allows safe rm variants" begin
        @test _check_exec_denylist("rm file.txt") === nothing
        @test _check_exec_denylist("rm -r ./build") === nothing  # recursive but not forced
        @test _check_exec_denylist("rm -i important.txt") === nothing
    end

    @testset "blocks dd disk writes" begin
        @test _check_exec_denylist("dd if=/dev/zero of=/dev/sda") !== nothing
        @test _check_exec_denylist("dd if=/dev/urandom of=/dev/sdb bs=4M") !== nothing
        @test _check_exec_denylist("dd if=image.iso of=/dev/disk2") !== nothing
    end

    @testset "allows safe dd variants" begin
        @test _check_exec_denylist("dd if=input.bin of=output.bin") === nothing
    end

    @testset "blocks mkfs" begin
        @test _check_exec_denylist("mkfs.ext4 /dev/sda1") !== nothing
        @test _check_exec_denylist("mkfs -t vfat /dev/sdb") !== nothing
    end

    @testset "blocks disk partitioning tools" begin
        @test _check_exec_denylist("fdisk /dev/sda") !== nothing
        @test _check_exec_denylist("parted /dev/sdb mklabel gpt") !== nothing
    end

    @testset "blocks fork bomb" begin
        @test _check_exec_denylist(":(){ :|:& };:") !== nothing
    end

    @testset "blocks system shutdown/reboot" begin
        @test _check_exec_denylist("shutdown -h now") !== nothing
        @test _check_exec_denylist("reboot") !== nothing
        @test _check_exec_denylist("sudo halt") !== nothing
        @test _check_exec_denylist("poweroff") !== nothing
    end

    @testset "blocks overwrite of critical system files" begin
        @test _check_exec_denylist("echo foo > /etc/passwd") !== nothing
        @test _check_exec_denylist("cat x > /etc/sudoers") !== nothing
    end

    @testset "allows normal commands" begin
        @test _check_exec_denylist("ls -la") === nothing
        @test _check_exec_denylist("git status") === nothing
        @test _check_exec_denylist("julia --version") === nothing
        @test _check_exec_denylist("cat README.md") === nothing
        @test _check_exec_denylist("mkdir -p ./output") === nothing
        @test _check_exec_denylist("cp src/foo.jl dst/foo.jl") === nothing
        @test _check_exec_denylist("grep -r 'pattern' ./src") === nothing
    end
end

@testset "SSRF: _is_forbidden_ip" begin
    @testset "blocks IPv4 private/reserved ranges" begin
        @test _is_forbidden_ip(IPv4("127.0.0.1"))       # loopback
        @test _is_forbidden_ip(IPv4("10.0.0.1"))        # 10/8
        @test _is_forbidden_ip(IPv4("10.255.255.255"))
        @test _is_forbidden_ip(IPv4("172.16.0.1"))      # 172.16/12
        @test _is_forbidden_ip(IPv4("172.31.255.255"))
        @test _is_forbidden_ip(IPv4("192.168.0.1"))     # 192.168/16
        @test _is_forbidden_ip(IPv4("169.254.169.254")) # link-local / cloud metadata
        @test _is_forbidden_ip(IPv4("0.0.0.0"))         # reserved
        @test _is_forbidden_ip(IPv4("100.64.0.1"))      # shared address space
    end

    @testset "allows public IPv4" begin
        @test !_is_forbidden_ip(IPv4("8.8.8.8"))
        @test !_is_forbidden_ip(IPv4("1.1.1.1"))
        @test !_is_forbidden_ip(IPv4("93.184.216.34"))
    end

    @testset "blocks IPv6 private/reserved" begin
        @test _is_forbidden_ip(IPv6("::1"))             # loopback
        @test _is_forbidden_ip(IPv6("::"))              # unspecified
        @test _is_forbidden_ip(IPv6("fe80::1"))         # link-local
        @test _is_forbidden_ip(IPv6("fd00::1"))         # ULA
        @test _is_forbidden_ip(IPv6("fc00::1"))         # ULA
    end

    @testset "allows public IPv6" begin
        @test !_is_forbidden_ip(IPv6("2606:4700:4700::1111"))  # Cloudflare DNS
    end
end

@testset "SSRF: _validate_http_url" begin
    @testset "blocks IP-literal private addresses in URL" begin
        url, err = _validate_http_url("http://127.0.0.1/secret")
        @test url === nothing
        @test err !== nothing

        url, err = _validate_http_url("http://169.254.169.254/latest/meta-data/")
        @test url === nothing
        @test err !== nothing

        url, err = _validate_http_url("http://192.168.1.1/admin")
        @test url === nothing
        @test err !== nothing
    end

    @testset "blocks localhost" begin
        url, err = _validate_http_url("http://localhost/")
        @test url === nothing
        @test err !== nothing
    end

    @testset "blocks non-http schemes" begin
        url, err = _validate_http_url("file:///etc/passwd")
        @test url === nothing

        url, err = _validate_http_url("ftp://example.com/file")
        @test url === nothing
    end

    @testset "allows public URLs" begin
        url, err = _validate_http_url("https://example.com/page")
        @test err === nothing
        @test url !== nothing
    end
end

@testset "Exec URL scan" begin
    @testset "blocks commands with internal URLs" begin
        @test _check_exec_urls("curl http://169.254.169.254/latest/meta-data/") !== nothing
        @test _check_exec_urls("wget http://192.168.1.1/admin") !== nothing
        @test _check_exec_urls("curl http://localhost/secret") !== nothing
        @test _check_exec_urls("curl http://10.0.0.1/internal") !== nothing
    end

    @testset "allows commands with public URLs" begin
        @test _check_exec_urls("curl https://example.com/data") === nothing
        @test _check_exec_urls("wget https://github.com/user/repo/archive.tar.gz") === nothing
        @test _check_exec_urls("git clone https://github.com/user/repo") === nothing
    end

    @testset "allows commands without URLs" begin
        @test _check_exec_urls("ls -la") === nothing
        @test _check_exec_urls("echo hello") === nothing
        @test _check_exec_urls("julia --version") === nothing
    end
end

@testset "Workspace path resolution" begin
    mktempdir() do workspace
        @testset "allows paths inside workspace" begin
            p = _resolve_path("file.txt", workspace; restrict_to_workspace = true)
            @test startswith(p, workspace)
        end

        @testset "blocks absolute paths outside workspace" begin
            @test_throws ArgumentError _resolve_path("/etc/passwd", workspace; restrict_to_workspace = true)
        end

        @testset "blocks path traversal" begin
            @test_throws ArgumentError _resolve_path("../../etc/passwd", workspace; restrict_to_workspace = true)
        end

        @testset "blocks symlink escape" begin
            # Create a symlink inside workspace pointing outside
            target = tempname()
            write(target, "secret")
            link = joinpath(workspace, "escape_link")
            symlink(target, link)
            @test_throws ArgumentError _resolve_path("escape_link", workspace; restrict_to_workspace = true)
            rm(target)
        end

        @testset "allows path when restriction disabled" begin
            p = _resolve_path("/etc/hosts", workspace; restrict_to_workspace = false)
            @test p == "/etc/hosts"
        end
    end
end

println("\n✅ All security tests passed!")
