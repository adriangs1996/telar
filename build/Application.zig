const std = @import("std");
const Coverage = @import("Coverage.zig");
const Modules = @import("Modules.zig");
const ModuleGraph = @import("ModuleGraph.zig");
const BinaryFlags = @import("BinaryFlags.zig");
const native_libraries = @import("native_libraries.zig");
/// Its `version` is the one a release publishes; tags must match it.
const manifest = @import("../build.zig.zon");
const assets_build = @import("assets.zig");

modules: Modules,
coverage: Coverage,
exe: *std.Build.Step.Compile,
install: *std.Build.Step.InstallArtifact,

/// Assemble the shipped module graph and run/install steps: `Application.init(b)`.
pub fn init(b: *std.Build) ?@This() {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = Coverage.init(b);
    // Third-party C, like the emulator, stays optimized in Debug builds.
    const natives = native_libraries.create(b, target, if (optimize == .Debug) .ReleaseFast else optimize);
    const graph = ModuleGraph.create(b, target, optimize, natives, coverage) orelse return null;
    // Dependents of this package import the shipped graph by name.
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "telar-core", graph.core },
        .{ "telar-lua", graph.telar_lua },
        .{ "telar-backend", graph.backend },
        .{ "model", graph.data },
    }) |exported| {
        b.modules.put(b.allocator, b.dupe(exported[0]), exported[1]) catch @panic("out of memory");
    }

    const assets = assets_build.add(b, target, optimize);
    const diagnostics_enabled = b.option(
        bool,
        "diagnostics",
        "Collect development telemetry in optimized builds",
    ) orelse false;
    // A headless build leaves out `telar gui`, and with it every desktop
    // library, so the same runtime installs on a server without them.
    const native_client = (b.option(bool, "gui", "Build the native client behind `telar gui` (default: true on macOS and Linux)") orelse true) and
        (target.result.os.tag == .macos or target.result.os.tag == .linux);
    const exe_options = binaryOptions(b, .{
        .native_client = native_client,
        .diagnostics = diagnostics_enabled,
        .echo_trace = b.option(bool, "echo-trace", "Record bounded echo phase timestamps until shutdown") orelse false,
        .echo_trace_cpu = b.option(bool, "echo-trace-cpu", "Include thread CPU clocks in diagnostic echo traces") orelse false,
        .profile_counts = b.option(bool, "profile-counts", "Collect bounded per-thread data-access counters") orelse false,
        .profile_timing = b.option(bool, "profile-timing", "Collect bounded synchronous phase histograms") orelse false,
    });
    const modules = graph.modules(assets, exe_options, native_client);
    // One shipped binary contains both the client and runtime entry points.
    const exe = b.addExecutable(.{
        .name = "telar",
        .root_module = mainModule(b, modules, b.option(bool, "strip", "Leave debug information out of the telar executable")),
    });
    // `zig build` installs only the shipped binary. Examples and probes get
    // their own steps so the default build and `run` never wait on them.
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_exe = b.addRunArtifact(exe);
    // Build-runner color overrides leak into panes and can downgrade truecolor.
    run_exe.color = .manual;
    run_exe.step.dependOn(&install_exe.step);
    run_exe.setEnvironmentVariable(
        "TELAR_DEVELOPMENT_CONFIG",
        b.pathFromRoot("dev/config.lua"),
    );
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    b.step("run", "Run telar").dependOn(&run_exe.step);

    return .{ .modules = modules, .coverage = coverage, .exe = exe, .install = install_exe };
}

/// The `build_options` of one telar executable, with the published version.
///
/// ```zig
/// const options = Application.binaryOptions(b, .{ .native_client = true });
/// ```
pub fn binaryOptions(b: *std.Build, flags: BinaryFlags) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "native_client", flags.native_client);
    options.addOption(bool, "diagnostics", flags.diagnostics);
    options.addOption(bool, "echo_trace", flags.echo_trace);
    options.addOption(bool, "echo_trace_cpu", flags.echo_trace_cpu);
    options.addOption(bool, "profile_counts", flags.profile_counts);
    options.addOption(bool, "profile_timing", flags.profile_timing);
    return options;
}

/// The root module of the telar executable, the client and runtime entry
/// points with every import but the native client's, which `gui.add` adds.
///
/// ```zig
/// const exe = b.addExecutable(.{ .name = "telar", .root_module = Application.mainModule(b, modules, null) });
/// ```
pub fn mainModule(b: *std.Build, modules: Modules, strip: ?bool) *std.Build.Module {
    const main = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .link_libc = true,
        .strip = strip,
    });
    main.addImport("telar-backend", modules.backend);
    main.addImport("telar-client", modules.client);
    main.addImport("model", modules.data);
    main.addImport("telar-core", modules.core);
    main.addImport("ghostty-vt", modules.ghostty_vt);
    modules.libraries.addImports(main);
    main.addOptions("build_options", modules.build_options);
    Modules.addInstaller(b, main);
    return main;
}
