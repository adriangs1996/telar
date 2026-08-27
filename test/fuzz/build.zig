const std = @import("std");
const builtin = @import("builtin");
const afl = @import("afl");

const Seed = struct {
    name: []const u8,
    bytes: []const u8,
};

const ModuleKind = enum {
    schema,
    escape,
};

const Fuzzer = struct {
    name: []const u8,
    source: []const u8,
    module: ModuleKind,
    seeds: []const Seed,
};

const client_seeds = [_]Seed{
    .{ .name = "empty", .bytes = "" },
    .{ .name = "runtime-stop", .bytes = "\x07" },
    .{ .name = "request-runtime-state", .bytes = "\x14" },
    .{ .name = "configure-graphics-shared", .bytes = "\x13\x01" },
    .{ .name = "pane-input", .bytes = "\x02\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00x" },
};

const server_seeds = [_]Seed{
    .{ .name = "empty", .bytes = "" },
    .{ .name = "runtime-stopping", .bytes = "\x85" },
    .{ .name = "proxy-inactive", .bytes = "\x95\x00" },
    .{ .name = "pane-cwd", .bytes = "\x99\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00/" },
    .{ .name = "pane-clipboard", .bytes = "\x9a\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00x" },
};

const escape_seeds = [_]Seed{
    .{ .name = "empty", .bytes = "" },
    .{ .name = "line-submit", .bytes = "\x04hello\n" },
    .{ .name = "osc-133-bel", .bytes = "\x08\x1b]133;A\x07" },
    .{ .name = "kitty-apc", .bytes = "\x10\x1b_Gm=0;AAAA\x1b\\" },
    .{ .name = "bracketed-paste", .bytes = "\x03\x1b[200~in\npaste\x1b[201~\r" },
};

const fuzzers = [_]Fuzzer{
    .{
        .name = "schema-client",
        .source = "src/fuzz_schema_client.zig",
        .module = .schema,
        .seeds = &client_seeds,
    },
    .{
        .name = "schema-server",
        .source = "src/fuzz_schema_server.zig",
        .module = .schema,
        .seeds = &server_seeds,
    },
    .{
        .name = "escape",
        .source = "src/fuzz_escape.zig",
        .module = .escape,
        .seeds = &escape_seeds,
    },
};

pub fn build(b: *std.Build) void {
    // Keep emitted bitcode generic enough for the LLVM bundled with afl-cc.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = builtin.target.cpu.arch,
        .cpu_model = .baseline,
        .os_tag = builtin.target.os.tag,
        .abi = builtin.target.abi,
    });
    const optimize = b.standardOptimizeOption(.{});
    const check_step = b.step("check", "Build fuzzers and replay the seed corpus");

    const unicode = b.createModule(.{
        .root_source_file = b.path("../../src/core/unicode_fake.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core = b.createModule(.{
        .root_source_file = b.path("../../src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("unicode", unicode);
    core.fuzz = true;

    const escape = b.createModule(.{
        .root_source_file = b.path("../../src/backend/history/escape.zig"),
        .target = target,
        .optimize = optimize,
    });
    escape.fuzz = true;

    inline for (fuzzers) |fuzzer| {
        const module = b.createModule(.{
            .root_source_file = b.path(fuzzer.source),
            .target = target,
            .optimize = optimize,
        });
        module.fuzz = true;
        switch (fuzzer.module) {
            .schema => module.addImport("telar-core", core),
            .escape => module.addImport("telar-history-escape", escape),
        }

        const lib = b.addLibrary(.{
            .name = fuzzer.name,
            .root_module = module,
            .use_llvm = true,
        });
        lib.root_module.stack_check = false;
        lib.root_module.fuzz = true;

        const exe = afl.addInstrumentedExe(b, lib);
        const install = b.addInstallBinFile(exe, b.fmt("fuzz-{s}", .{fuzzer.name}));
        b.getInstallStep().dependOn(&install.step);

        const corpus_dir = addSeedCorpus(b, fuzzer);
        const run = afl.addFuzzerRun(
            b,
            exe,
            corpus_dir,
            b.path(b.fmt("afl-out/{s}", .{fuzzer.name})),
        );
        run.setEnvironmentVariable("AFL_AUTORESUME", "1");
        b.step(
            b.fmt("run-{s}", .{fuzzer.name}),
            b.fmt("Run {s} with afl-fuzz", .{fuzzer.name}),
        ).dependOn(&run.step);

        inline for (fuzzer.seeds) |seed| {
            const replay = std.Build.Step.Run.create(
                b,
                b.fmt("replay {s}/{s}", .{ fuzzer.name, seed.name }),
            );
            replay.addFileArg(exe);
            replay.setStdIn(.{ .bytes = seed.bytes });
            replay.expectExitCode(0);
            check_step.dependOn(&replay.step);
        }
    }
}

fn addSeedCorpus(b: *std.Build, comptime fuzzer: Fuzzer) std.Build.LazyPath {
    const corpus = b.addWriteFiles();
    inline for (fuzzer.seeds) |seed| {
        _ = corpus.add(seed.name, seed.bytes);
    }
    return corpus.getDirectory();
}
