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
const WaitArgs = @import("WaitArgs.zig");
const Adoption = @import("Adoption.zig");
const ResolveArgs = @import("ResolveArgs.zig");
const RejectContext = @import("RejectContext.zig");
const Generation = @import("../config/Generation.zig");
const Orphans = @import("Orphans.zig");
const Registry = @import("../plugins/Registry.zig");
const privatefile = @import("privatefile");
const std = @import("std");
const BackgroundJob = @import("../execution/BackgroundJob.zig").BackgroundJob;

/// Seeds the trust store's watch fingerprint apart from the other watched files.
const trust_fingerprint_seed = 0x74656c61722d7472;
/// The largest trust store the watch loads, in bytes.
const trust_store_limit = 64 * 1024;

pub const ConfigReload = union(enum) {
    unchanged: i128,
    loaded: Loaded,
    failed: struct {
        diagnostic: data.Diagnostic,
        mtime_ns: i128,
    },
};

/// The next asynchronous watch, using the current reload fingerprint. It
/// consumes a forced reload; the caller queues the job.
///
/// ```zig
/// try client.to_background.push(schedule(&state, args));
/// ```
pub fn schedule(state: *ConfigReloadState, args: ScheduleArgs) BackgroundJob {
    defer state.force_next = false;

    return .{
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
    };
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
    const generation = Generation.loadFile(.{
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
    const registry = args.gpa.create(Registry) catch {
        partial.abandon(args.gpa, args.orphans);
        diagnostic.set("cannot allocate reloaded plugin registry", .{});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    partial.registry = registry;
    registry.* = Registry.loadWithTrust(
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
    return privatefile.fingerprint(io, path, trust_fingerprint_seed);
}

fn loadReloadTrustStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*core.TrustStore {
    const store = try gpa.create(core.TrustStore);
    errdefer gpa.destroy(store);

    const source = privatefile.read(io, gpa, path, .limited(trust_store_limit)) catch |err| switch (err) {
        error.InsecureFile => return error.InsecureTrustStore,
        else => |other| return other,
    } orelse {
        store.* = .{};
        return store;
    };
    defer gpa.free(source);

    store.* = try core.TrustStore.parse(gpa, source);
    return store;
}

test "a rejected load is freed once and reports why" {
    // The unwind concentrates here: rejecting a loaded configuration frees
    // the three objects and clears the orphan slots in one place.
    var state: ConfigReloadState = .{ .mtime_ns = 0 };
    const gpa = std.testing.allocator;
    const registry = try gpa.create(Registry);
    const trust = try gpa.create(core.TrustStore);
    trust.* = .{};
    var diagnostic: data.Diagnostic = .{};
    const generation = try Generation.loadSource(.{
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

test "a forced reload is consumed by the one watch that carries it" {
    var state: ConfigReloadState = .{ .mtime_ns = 0, .force_next = true };
    const args: ScheduleArgs = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .path = "/config.lua",
        .profile = null,
        .trust_path = "/trust.json",
        .current_generation = @ptrFromInt(@alignOf(Generation)),
        .current_registry = @ptrFromInt(@alignOf(Registry)),
    };

    try std.testing.expect(schedule(&state, args).config_watch.force_reload);
    try std.testing.expect(!state.force_next);
    try std.testing.expect(!schedule(&state, args).config_watch.force_reload);
}

const Partial = struct {
    /// The pieces the async task has built so far, so every failure unwinds
    /// through one place instead of repeating the partial free by hand.
    generation: *Generation,
    trust: ?*core.TrustStore = null,
    registry: ?*Registry = null,

    pub fn abandon(self: Partial, gpa: std.mem.Allocator, orphans: *Orphans) void {
        orphans.* = .{};
        if (self.registry) |registry| {
            gpa.destroy(registry);
        }
        self.generation.deinit();
        if (self.trust) |trust| {
            gpa.destroy(trust);
        }
    }
};

const ScheduleArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    profile: ?[]const u8,
    trust_path: []const u8,
    current_generation: *const Generation,
    current_registry: *const Registry,
};
