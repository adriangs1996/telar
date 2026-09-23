//! Configuration hot reload: the fingerprint watch, the asynchronous load
//! and validation, the orphan handoff that lets a cancelled task still be
//! freed, and one unwind for every rejection. `resolve` hands the client
//! an adoption to apply — nothing here touches client state beyond the
//! module's own.

const data = @import("model");
const default_bindings = @import("../config/default_bindings.zig");
const core = @import("telar-core");
const Loaded = @import("Loaded.zig");
const ConfigReloadState = @import("ConfigReloadState.zig");
const ScheduleArgs = @import("ScheduleArgs.zig");
const WaitArgs = @import("WaitArgs.zig");
const Adoption = @import("Adoption.zig");
const ResolveArgs = @import("ResolveArgs.zig");
const RejectContext = @import("RejectContext.zig");
const GenerationType = @import("../config/Generation.zig");
const Partial = @import("Partial.zig");
const RegistryType = @import("../plugins/Registry.zig");
const std = @import("std");
const Job = @import("../execution/Job.zig").Job;

pub const ConfigReload = union(enum) {
    unchanged: i128,
    loaded: Loaded,
    failed: struct {
        diagnostic: data.Diagnostic,
        mtime_ns: i128,
    },
};

/// Schedules one asynchronous watch using the current reload fingerprint.
///
/// ```zig
/// try schedule(&state, args);
/// ```
pub fn schedule(state: *ConfigReloadState, args: ScheduleArgs) !void {
    try args.workers.start(.{
        .config_watch = .{
            .io = args.io,
            .gpa = args.gpa,
            .path = args.path,
            .known_mtime_ns = state.mtime_ns,
            .force_reload = state.force_next,
            .plugin_overrides = state.plugin_overrides,
            .generation_number = state.next_generation,
            .profile = args.profile,
            .current_generation = args.current_generation,
            .current_registry = args.current_registry,
            .trust_path = args.trust_path,
            .orphans = &state.orphans,
        },
    });
    state.force_next = false;
}

pub const Outcome = union(enum) {
    unchanged,
    rejected: data.Diagnostic,
    adopted: Adoption,
};

/// Resolves one finished reload attempt. A rejection frees the loaded
/// objects and clears the orphan slots here — the unwind lives once. An
/// adoption clears the slots and hands the objects to the caller, which
/// owns applying and swapping them.
///
/// ```zig
/// const outcome = resolve(&state, args);
/// ```
pub fn resolve(state: *ConfigReloadState, args: ResolveArgs) Outcome {
    switch (args.reload) {
        .unchanged => |mtime_ns| {
            state.mtime_ns = mtime_ns;
            return .unchanged;
        },
        .failed => |failure| {
            state.mtime_ns = failure.mtime_ns;
            return .{ .rejected = failure.diagnostic };
        },
        .loaded => |loaded| {
            const rejection: RejectContext = .{ .state = state, .gpa = args.gpa, .loaded = loaded };
            const snapshot = &loaded.generation.snapshot;
            const requested_sidebar = if (args.checks.sidebar_renderer_locked)
                args.checks.current_sidebar
            else
                snapshot.sidebar_rendering;
            _ = requested_sidebar.resolve(args.checks.kitty_support) catch |err| return rejection.reject(
                "reloaded sidebar renderer is unavailable: {s}",
                .{@errorName(err)},
            );
            default_bindings.validate(snapshot.prefix, snapshot.bindingSlice()) catch |err| return rejection.reject(
                "reloaded keymap is invalid: {s}",
                .{@errorName(err)},
            );
            state.clearOrphans();
            state.mtime_ns = loaded.mtime_ns;
            state.next_generation += 1;
            return .{ .adopted = .{
                .generation = loaded.generation,
                .registry = loaded.registry,
                .trust_store = loaded.trust_store,
                .input = .{
                    .prefix = snapshot.prefix,
                    .bindings = snapshot.bindingSlice(),
                    .escape_timeout_ns = snapshot.input_escape_timeout_ns,
                    .sequence_timeout_ns = snapshot.input_sequence_timeout_ns,
                },
                .sidebar_rendering = requested_sidebar,
            } };
        },
    }
}

/// The watch task body an adapter runs off the interactive path.
pub fn wait(args: WaitArgs) anyerror!ConfigReload {
    try args.io.sleep(.fromSeconds(1), .awake);
    const mtime_ns = args.current_generation.watchFingerprint(args.io, args.path) ^
        @as(i128, args.current_registry.watchFingerprint(args.gpa, args.io)) ^
        @as(i128, trustWatchFingerprint(args.io, args.trust_path));
    if (!args.force_reload and mtime_ns == args.known_mtime_ns) {
        return .{ .unchanged = mtime_ns };
    }
    var diagnostic: data.Diagnostic = .{};
    const generation = GenerationType.loadFile(.{
        .gpa = args.gpa,
        .io = args.io,
        .diagnostic = &diagnostic,
    }, .{
        .path = args.path,
        .number = args.generation_number,
        .profile = args.profile,
    }) catch return .{ .failed = .{
        .diagnostic = diagnostic,
        .mtime_ns = mtime_ns,
    } };
    args.plugin_overrides.apply(&generation.snapshot);
    args.orphans.generation = generation;
    var partial: Partial = .{ .generation = generation };
    const trust = loadReloadTrustStore(args.gpa, args.io, args.trust_path) catch |err| {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot load plugin trust store: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    args.orphans.trust = trust;
    partial.trust = trust;
    const registry = args.gpa.create(RegistryType) catch {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot allocate reloaded plugin registry", .{});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    partial.registry = registry;
    registry.* = RegistryType.loadWithTrust(
        .{
            .gpa = args.gpa,
            .io = args.io,
            .config_dir = generation.configDir(),
        },
        generation.pluginSlice(),
        trust,
    ) catch |err| {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot load plugins: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    registry.validateConfiguredActions(generation.snapshot.bindingSlice()) catch |err| {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("invalid configured plugin action: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    args.orphans.registry = registry;
    return .{ .loaded = .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust,
        .mtime_ns = generation.watchFingerprint(args.io, args.path) ^
            @as(i128, registry.watchFingerprint(args.gpa, args.io)) ^
            @as(i128, trustWatchFingerprint(args.io, args.trust_path)),
    } };
}

pub fn trustWatchFingerprint(io: std.Io, path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d7472);
    hasher.update(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
        hasher.update("\x00missing");
        return hasher.final();
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    return hasher.final();
}

fn loadReloadTrustStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*core.TrustStore {
    const store = try gpa.create(core.TrustStore);
    errdefer gpa.destroy(store);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            store.* = .{};
            return store;
        },
        else => return err,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureTrustStore;
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(source);
    store.* = try core.TrustStore.parse(gpa, source);
    return store;
}

test "a rejected load is freed once and reports why" {
    // The unwind concentrates here: rejecting a loaded configuration frees
    // the three objects and clears the orphan slots in one place.
    var state: ConfigReloadState = .{ .mtime_ns = 0 };
    const gpa = std.testing.allocator;
    const registry = try gpa.create(RegistryType);
    const trust = try gpa.create(core.TrustStore);
    trust.* = .{};
    var diagnostic: data.Diagnostic = .{};
    const generation = try GenerationType.loadSource(.{
        .gpa = gpa,
        .io = std.testing.io,
        .diagnostic = &diagnostic,
    }, .{
        .source =
        \\local telar = require("telar")
        \\local config = telar.config({ api_version = 2 })
        \\return config
        ,
        .source_name = "@reload-test",
        .number = 1,
    });
    state.orphans = .{ .generation = generation, .registry = registry, .trust = trust };

    const rejection: RejectContext = .{
        .state = &state,
        .gpa = gpa,
        .loaded = .{ .generation = generation, .registry = registry, .trust_store = trust, .mtime_ns = 9 },
    };
    const outcome = rejection.reject("test rejection: {s}", .{"boom"});
    try std.testing.expect(outcome == .rejected);
    try std.testing.expectEqual(@as(i128, 9), state.mtime_ns);
    try std.testing.expect(state.orphans.generation == null);
    try std.testing.expect(state.orphans.registry == null);
    try std.testing.expect(state.orphans.trust == null);
}

test "forced reload survives scheduling failure and is consumed by a successful worker" {
    const Capture = struct {
        force: bool = false,
        fail: bool = true,
        fn start(raw: *anyopaque, job: Job) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.force = job.config_watch.force_reload;
            if (self.fail) {
                return error.WatcherBusy;
            }
        }
    };
    var capture: Capture = .{};
    var state: ConfigReloadState = .{ .mtime_ns = 0, .force_next = true };
    const args: ScheduleArgs = .{ .io = std.testing.io, .gpa = std.testing.allocator, .workers = .{ .context = &capture, .start_fn = Capture.start }, .path = "/config.lua", .profile = null, .trust_path = "/trust.json", .current_generation = @ptrFromInt(@alignOf(GenerationType)), .current_registry = @ptrFromInt(@alignOf(RegistryType)) };
    try std.testing.expectError(error.WatcherBusy, schedule(&state, args));
    try std.testing.expect(state.force_next);
    capture.fail = false;
    try schedule(&state, args);
    try std.testing.expect(capture.force);
    try std.testing.expect(!state.force_next);
    try schedule(&state, args);
    try std.testing.expect(!capture.force);
}
