//! Physical resources acquired and owned for one runtime lifetime.

const std = @import("std");
const core = @import("telar-core");
const pty = @import("../../pty/root.zig");
const transport = @import("../../transport/root.zig");
const client_store = @import("../client/root.zig").store;
const config = @import("../config.zig");
const history_runtime = @import("history.zig");
const attachment = @import("../attachment/root.zig");
const proxy_runtime = @import("proxy.zig");
const telemetry = @import("../observability/root.zig").telemetry;

const Io = std.Io;
const diagnostics = core.diagnostics;

const AcquisitionPhase = enum {
    child_environment,
    proxy,
    listener,
    telemetry,
    clients,
    history,
};

/// Owns runtime-wide physical resources acquired during startup.
pub const Resources = struct {
    dependencies: config.Dependencies,
    heap: diagnostics.Heap,
    gpa: std.mem.Allocator,
    child_environment: pty.ChildEnvironment,
    /// Immutable after startup; observation workers borrow it by pointer.
    agent_manifests: core.agent_manifest.Table,
    proxy: proxy_runtime.Runtime,
    listener: transport.local.LocalListener,
    telemetry: telemetry.State,
    clients: *client_store.Store,
    history: history_runtime.Runtime,

    /// Acquires physical resources in dependency order and rolls back every
    /// completed acquisition if a later one fails.
    ///
    /// ```zig
    /// var resources: Resources = undefined;
    /// try resources.init(initialization);
    /// ```
    pub fn init(resources: *Resources, initialization: config.Initialization) !void {
        return resources.acquire(initialization, null);
    }

    fn acquire(resources: *Resources, initialization: config.Initialization, comptime fail_after: ?AcquisitionPhase) !void {
        resources.dependencies = initialization.dependencies;
        resources.heap = diagnostics.Heap.init(initialization.dependencies.allocator);
        resources.gpa = resources.heap.allocator();

        try initialization.options.graphics.validate();
        attachment.initSharedFreezeNonce(resources.io());

        resources.agent_manifests = initialization.options.agent_manifests;
        resources.child_environment = try pty.ChildEnvironment.init(resources.gpa, initialization.options.environment, "telar");
        errdefer resources.child_environment.deinit();
        try checkpoint(fail_after, .child_environment);

        resources.proxy = try proxy_runtime.Runtime.init(resources.io(), resources.gpa, initialization.options.proxy);
        errdefer resources.proxy.deinit();
        try checkpoint(fail_after, .proxy);

        resources.listener = try transport.local.LocalListener.listen(resources.io(), initialization.options.endpoint);
        errdefer resources.listener.deinit(resources.io());
        try checkpoint(fail_after, .listener);

        resources.telemetry = initTelemetry(resources.io(), initialization.options.endpoint);
        errdefer resources.telemetry.deinit(resources.io());
        try checkpoint(fail_after, .telemetry);

        resources.clients = try createClientStore(resources.gpa);
        errdefer resources.gpa.destroy(resources.clients);
        try checkpoint(fail_after, .clients);

        resources.history = try history_runtime.Runtime.init(resources.io(), resources.gpa, initialization.options.history_path);
        errdefer resources.history.deinit();
        try checkpoint(fail_after, .history);
    }

    /// Returns the I/O implementation selected by the process root.
    ///
    /// ```zig
    /// const io = resources.io();
    /// ```
    pub fn io(resources: *const Resources) Io {
        return resources.dependencies.io;
    }

    /// Releases resources acquired before actors were started.
    ///
    /// ```zig
    /// resources.deinitUnstarted();
    /// ```
    pub fn deinitUnstarted(resources: *Resources) void {
        resources.history.deinit();
        resources.gpa.destroy(resources.clients);
        resources.telemetry.deinit(resources.io());
        resources.listener.deinit(resources.io());
        resources.proxy.deinit();
        resources.child_environment.deinit();
    }
};

fn checkpoint(comptime fail_after: ?AcquisitionPhase, comptime phase: AcquisitionPhase) !void {
    if (comptime fail_after == phase) {
        return error.InjectedStartupFailure;
    }
}

fn initTelemetry(io: Io, endpoint: []const u8) telemetry.State {
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "runtime-{d}", .{std.c.getpid()}) catch "runtime";
    return telemetry.State.init(io, endpoint, suffix);
}

fn createClientStore(gpa: std.mem.Allocator) !*client_store.Store {
    const clients = try gpa.create(client_store.Store);
    clients.* = .{};
    return clients;
}

test "every resource acquisition checkpoint rolls back" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);

    inline for (std.enums.values(AcquisitionPhase), 0..) |phase, index| {
        var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/resource-{d}.sock", .{ directory_buffer[0..directory_len], index });
        var resources: Resources = undefined;

        try std.testing.expectError(error.InjectedStartupFailure, resources.acquire(.{
            .dependencies = .{ .io = io, .allocator = std.testing.allocator },
            .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
        }, phase));

        try std.testing.expectError(
            error.FileNotFound,
            Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
        );
    }
}
