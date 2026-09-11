//! Configuration hot reload: the fingerprint watch, the asynchronous load
//! and validation, the orphan handoff that lets a cancelled task still be
//! freed, and one unwind for every rejection. `resolve` hands the client
//! an adoption to apply — nothing here touches client state beyond the
//! module's own.

const std = @import("std");
const core = @import("telar-core");
const graphics = @import("../../graphics/root.zig");
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
pub const kitty = graphics.kitty;
const host_inputs = @import("../controllers/input/host_inputs.zig");

pub const Io = std.Io;

const client_mod = @import("../Client.zig");
pub const ClientEvent = client_mod.ClientEvent;
pub const InputRouter = host_inputs.Router;

pub const ConfigReload = union(enum) {
    unchanged: i128,
    loaded: Loaded,
    failed: struct {
        diagnostic: lua_config.Diagnostic,
        mtime_ns: i128,
    },
};

pub const Loaded = @import("Loaded.zig");

const Orphans = @import("Orphans.zig");

pub const State = @import("ConfigReloadState.zig");

pub const ScheduleArgs = @import("ScheduleArgs.zig");

/// Schedules one asynchronous watch using the current reload fingerprint.
///
/// ```zig
/// try schedule(&state, args);
/// ```
pub fn schedule(state: *State, args: ScheduleArgs) !void {
    try args.select.concurrent(.config_reload, waitConfigReload, .{
        WaitArgs{
            .io = args.io,
            .gpa = args.gpa,
            .path = args.path,
            .known_mtime_ns = state.mtime_ns,
            .generation_number = state.next_generation,
            .profile = args.profile,
            .current_generation = args.current_generation,
            .current_registry = args.current_registry,
            .trust_path = args.trust_path,
            .orphans = &state.orphans,
        },
    });
}

pub const Checks = @import("Checks.zig");

pub const ResolveArgs = @import("ResolveArgs.zig");

pub const Adoption = @import("Adoption.zig");

pub const Outcome = union(enum) {
    unchanged,
    rejected: lua_config.Diagnostic,
    adopted: Adoption,
};

const RejectContext = @import("RejectContext.zig");

/// Resolves one finished reload attempt. A rejection frees the loaded
/// objects and clears the orphan slots here — the unwind lives once. An
/// adoption clears the slots and hands the objects to the caller, which
/// owns applying and swapping them.
///
/// ```zig
/// const outcome = resolve(&state, args);
/// ```
pub fn resolve(state: *State, args: ResolveArgs) Outcome {
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
            const router = host_inputs.buildRouter(.{
                .prefix = snapshot.prefix,
                .bindings = snapshot.bindingSlice(),
                .escape_timeout_ns = snapshot.input_escape_timeout_ns,
                .sequence_timeout_ns = snapshot.input_sequence_timeout_ns,
            }) catch |err| return rejection.reject(
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
                .router = router,
                .sidebar_rendering = requested_sidebar,
            } };
        },
    }
}

const Partial = @import("Partial.zig");

const WaitArgs = @import("WaitArgs.zig");

fn waitConfigReload(args: WaitArgs) anyerror!ConfigReload {
    try args.io.sleep(.fromSeconds(1), .awake);
    const mtime_ns = args.current_generation.watchFingerprint(args.io, args.path) ^
        @as(i128, args.current_registry.watchFingerprint(args.gpa, args.io)) ^
        @as(i128, trustWatchFingerprint(args.io, args.trust_path));
    if (mtime_ns == args.known_mtime_ns) {
        return .{ .unchanged = mtime_ns };
    }
    var diagnostic: lua_config.Diagnostic = .{};
    const generation = lua_config.Generation.loadFile(.{
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
    args.orphans.generation = generation;
    var partial: Partial = .{ .generation = generation };
    const trust = loadReloadTrustStore(args.gpa, args.io, args.trust_path) catch |err| {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot load plugin trust store: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    args.orphans.trust = trust;
    partial.trust = trust;
    const registry = args.gpa.create(plugin_broker.Registry) catch {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot allocate reloaded plugin registry", .{});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    partial.registry = registry;
    registry.* = plugin_broker.Registry.loadWithTrust(
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

pub fn trustWatchFingerprint(io: Io, path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d7472);
    hasher.update(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
        hasher.update("\x00missing");
        return hasher.final();
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    return hasher.final();
}

fn loadReloadTrustStore(gpa: std.mem.Allocator, io: Io, path: []const u8) !*core.plugin.TrustStore {
    const store = try gpa.create(core.plugin.TrustStore);
    errdefer gpa.destroy(store);
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            store.* = .{};
            return store;
        },
        else => return err,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.InsecureTrustStore;
    }
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(source);
    store.* = try core.plugin.TrustStore.parse(gpa, source);
    return store;
}

test "a rejected load is freed once and reports why" {
    // The unwind concentrates here: rejecting a loaded configuration frees
    // the three objects and clears the orphan slots in one place.
    var state: State = .{ .mtime_ns = 0 };
    const gpa = std.testing.allocator;
    const registry = try gpa.create(plugin_broker.Registry);
    const trust = try gpa.create(core.plugin.TrustStore);
    trust.* = .{};
    var diagnostic: lua_config.Diagnostic = .{};
    const generation = try lua_config.Generation.loadSource(.{
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
