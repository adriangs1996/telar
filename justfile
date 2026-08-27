# Show the available commands.
default:
    @just --list

# Build Telar. Extra arguments are forwarded to `zig build`.
build *args:
    zig build {{ args }}

# Build an optimized Telar binary at `.zig-out/prod/bin/telar`.
release:
    zig build --prefix .zig-out/prod -Doptimize=ReleaseFast

stop:
  zig build run -- server stop

# Build and run Telar. Extra arguments are passed to Telar.
run *args:
    zig build run -- {{ args }}

# Format the project Zig sources.
fmt:
    zig fmt build.zig build.zig.zon src examples benchmarks

# Check formatting without changing files.
fmt-check:
    zig fmt --check build.zig build.zig.zon src examples benchmarks

# Run formatting checks and the complete test suite.
check: fmt-check test

# Run the complete test suite. Extra arguments are forwarded to `zig build`.
test *args:
    zig build test {{ args }}

# Run the native tests with zcov and write coverage.lcov.
coverage *args:
    tools/coverage.sh {{ args }}

# Run frontend tests.
test-frontend:
    zig build test-frontend

# Run transport tests.
test-transport:
    zig build test-transport

# Run protocol schema tests.
test-schema:
    zig build test-schema

# Run the standalone proxy tests.
test-proxy-example:
    zig build test-proxy-example

test-backend-proxy:
    zig build test-backend-proxy

# Build the standalone proxy example.
proxy:
    zig build proxy

# Run the sidebar example.
sidebar:
    zig build sidebar

# Run benchmarks. Extra arguments are passed to the benchmark executable.
bench *args:
    zig build bench -- {{ args }}

# List benchmark names.
bench-list:
    zig build bench -- --list

# Type-check platform-specific code for supported cross targets.
cross:
    zig build cross

# Run correctness, portability and performance release gates.
verify-release:
    zig build verify-release

# Exercise terminal-browser inside Telar. Extra arguments are forwarded.
verify-terminal-browser *args:
    zig build verify-terminal-browser -- {{ args }}

alias b := build
alias r := run
alias t := test
