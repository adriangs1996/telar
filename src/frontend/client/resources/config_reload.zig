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
const kitty = graphics.kitty;
const host_inputs = @import("../controllers/input/host_inputs.zig");

const Io = std.Io;

const client_mod = @import("../client.zig");
const ClientEvent = client_mod.ClientEvent;
const InputRouter = host_inputs.Router;

pub const ConfigReload = union(enum) {
    unchanged: i128,
    loaded: Loaded,
    failed: struct {
        diagnostic: lua_config.Diagnostic,
        mtime_ns: i128,
    },
};

pub const Loaded = struct {
    generation: *lua_config.Generation,
    registry: *plugin_broker.Registry,
    trust_store: *core.plugin.TrustStore,
    mtime_ns: i128,
};

const Orphans = struct {
    generation: ?*lua_config.Generation = null,
    registry: ?*plugin_broker.Registry = null,
    trust: ?*core.plugin.TrustStore = null,
};

/// The reload's own state on the client: the watch fingerprint, the
/// generation counter, and the race-window handoff slots the async task
/// publishes into so a cancelled reload can still be freed.
pub const State = struct {
    mtime_ns: i128,
    next_generation: u64 = 2,
    orphans: Orphans = .{},

    /// Frees whatever a cancelled reload task published. Call only after
    /// the select's tasks are cancelled.
    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        if (state.orphans.generation) |generation| {
            generation.deinit();
        }
        if (state.orphans.registry) |registry| {
            gpa.destroy(registry);
        }
        if (state.orphans.trust) |store| {
            gpa.destroy(store);
        }
    }

    fn clearOrphans(state: *State) void {
        state.orphans = .{};
    }
};

pub const ScheduleArgs = struct {
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(ClientEvent),
    path: []const u8,
    profile: ?[]const u8,
    trust_path: []const u8,
    current_generation: *const lua_config.Generation,
    current_registry: *const plugin_broker.Registry,
};

/// Schedules one asynchronous watch using the current reload fingerprint.
///
/// ```zig
/// try schedule(&state, args);
/// ```
pub fn schedule(state: *State, args: ScheduleArgs) !void {
    try args.select.concurrent(.config_reload, waitConfigReload, .{
        args.io,
        args.gpa,
        args.path,
        state.mtime_ns,
        state.next_generation,
        args.profile,
        args.current_generation,
        args.current_registry,
        args.trust_path,
        &state.orphans,
    });
}

/// The client facts `resolve` validates a loaded configuration against.
pub const Checks = struct {
    kitty_support: kitty.Support,
    sidebar_renderer_locked: bool,
    current_sidebar: kitty.SidebarRendering,
};

pub const ResolveArgs = struct {
    gpa: std.mem.Allocator,
    reload: ConfigReload,
    checks: Checks,
};

/// Everything a validated reload hands over: the owned configuration
/// objects and the values already compiled from them.
pub const Adoption = struct {
    generation: *lua_config.Generation,
    registry: *plugin_broker.Registry,
    trust_store: *core.plugin.TrustStore,
    router: InputRouter,
    sidebar_rendering: kitty.SidebarRendering,

    /// Releases an adoption that no client accepted.
    ///
    /// ```zig
    /// errdefer adoption.deinit(gpa);
    /// ```
    pub fn deinit(adoption: Adoption, gpa: std.mem.Allocator) void {
        adoption.generation.deinit();
        gpa.destroy(adoption.registry);
        gpa.destroy(adoption.trust_store);
    }
};

pub const Outcome = union(enum) {
    unchanged,
    rejected: lua_config.Diagnostic,
    adopted: Adoption,
};

const RejectContext = struct {
    state: *State,
    gpa: std.mem.Allocator,
    loaded: Loaded,

    fn reject(context: RejectContext, comptime format: []const u8, args: anytype) Outcome {
        var diagnostic: lua_config.Diagnostic = .{};
        diagnostic.set(format, args);
        context.state.clearOrphans();
        context.state.mtime_ns = context.loaded.mtime_ns;
        context.loaded.generation.deinit();
        context.gpa.destroy(context.loaded.registry);
        context.gpa.destroy(context.loaded.trust_store);

        return .{ .rejected = diagnostic };
    }
};

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

/// The pieces the async task has built so far, so every failure unwinds
/// through one place instead of repeating the partial free by hand.
const Partial = struct {
    generation: *lua_config.Generation,
    trust: ?*core.plugin.TrustStore = null,
    registry: ?*plugin_broker.Registry = null,

    fn abandon(partial: Partial, gpa: std.mem.Allocator, orphans: *Orphans) void {
        orphans.* = .{};
        if (partial.registry) |registry| {
            gpa.destroy(registry);
        }
        partial.generation.deinit();
        if (partial.trust) |trust| {
            gpa.destroy(trust);
        }
    }
};

fn waitConfigReload(io: Io, gpa: std.mem.Allocator, path: []const u8, known_mtime_ns: i128, generation_number: u64, profile: ?[]const u8, current_generation: *const lua_config.Generation, current_registry: *const plugin_broker.Registry, trust_path: []const u8, orphans: *Orphans) anyerror!ConfigReload {
    try io.sleep(.fromSeconds(1), .awake);
    const mtime_ns = current_generation.watchFingerprint(io, path) ^
        @as(i128, current_registry.watchFingerprint(gpa, io)) ^
        @as(i128, trustWatchFingerprint(io, trust_path));
    if (mtime_ns == known_mtime_ns) {
        return .{ .unchanged = mtime_ns };
    }
    var diagnostic: lua_config.Diagnostic = .{};
    const generation = lua_config.Generation.loadFileProfile(
        gpa,
        io,
        path,
        generation_number,
        profile,
        &diagnostic,
    ) catch return .{ .failed = .{
        .diagnostic = diagnostic,
        .mtime_ns = mtime_ns,
    } };
    orphans.generation = generation;
    var partial: Partial = .{ .generation = generation };
    const trust = loadReloadTrustStore(gpa, io, trust_path) catch |err| {
        partial.abandon(gpa, orphans);
        diagnostic.set("cannot load plugin trust store: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    orphans.trust = trust;
    partial.trust = trust;
    const registry = gpa.create(plugin_broker.Registry) catch {
        partial.abandon(gpa, orphans);
        diagnostic.set("cannot allocate reloaded plugin registry", .{});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    partial.registry = registry;
    registry.* = plugin_broker.Registry.loadWithTrust(
        gpa,
        io,
        generation.configDir(),
        generation.pluginSlice(),
        trust,
    ) catch |err| {
        partial.abandon(gpa, orphans);
        diagnostic.set("cannot load plugins: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    registry.validateConfiguredActions(generation.snapshot.bindingSlice()) catch |err| {
        partial.abandon(gpa, orphans);
        diagnostic.set("invalid configured plugin action: {s}", .{@errorName(err)});
        return .{ .failed = .{ .diagnostic = diagnostic, .mtime_ns = mtime_ns } };
    };
    orphans.registry = registry;
    return .{ .loaded = .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust,
        .mtime_ns = generation.watchFingerprint(io, path) ^
            @as(i128, registry.watchFingerprint(gpa, io)) ^
            @as(i128, trustWatchFingerprint(io, trust_path)),
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
    const generation = try lua_config.Generation.loadSource(
        gpa,
        std.testing.io,
        \\local telar = require("telar")
        \\local config = telar.config({ api_version = 2 })
        \\return config
    ,
        "@reload-test",
        1,
        &diagnostic,
    );
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
