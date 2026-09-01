//! Owns one client's host-TTY read, native router and replaceable deadlines.

const std = @import("std");
const input_capability = @import("../../../input/root.zig");
const lua_config = @import("../../../config/root.zig");
const widgets = @import("../../../widgets/root.zig");
const input_application = @import("../../application/input/root.zig");
const client_clock = @import("../../resources/clock.zig");
const deadline_timer = @import("../../resources/deadline_timer.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const Client = @import("../../client.zig");
const InputHandler = @import("../../resources/input_handler.zig");
const Io = std.Io;
const File = Io.File;
const Action = input_capability.action.Action;
const keybind = input_capability.keybind;
const key_routing = input_application.key_routing;

const chunk_size = 4096;
const held_binding_bytes = 128;

pub const Router = keybind.Router(
    Action,
    lua_config.max_bindings,
    lua_config.default_binding_max_keys,
    chunk_size,
    held_binding_bytes,
);

comptime {
    std.debug.assert(chunk_size <= runtime_transport.max_input_bytes);
}

pub const Chunk = struct {
    bytes: [chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(chunk: *const Chunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};

pub const Config = struct {
    prefix: keybind.Key,
    bindings: []const lua_config.ConfiguredBinding,
    escape_timeout_ns: u64,
    sequence_timeout_ns: u64,
};

/// Compiles an owned, allocation-free router from validated configuration.
///
/// ```zig
/// const router = try buildRouter(config);
/// ```
pub fn buildRouter(config: Config) !Router {
    const resolved = try lua_config.resolveBindings(config.prefix, config.bindings);
    var router = try Router.initWithPrefix(resolved.slice(), config.prefix);
    router.escape_timeout_ns = config.escape_timeout_ns;
    router.sequence_timeout_ns = config.sequence_timeout_ns;

    return router;
}

pub const State = struct {
    file: File,
    router: Router,
    read_pending: bool = false,
    presentation_revision: u64 = 0,
    input_timeout: deadline_timer.Scheduler = .{},
    binding_timeout: deadline_timer.Scheduler = .{},
    application_leases: key_routing.Leases = .{},

    /// Creates the host input state around the client-owned TTY handle.
    ///
    /// ```zig
    /// const state = try State.init(input_file, config);
    /// ```
    pub fn init(file: File, config: Config) !State {
        return .{ .file = file, .router = try buildRouter(config) };
    }

    /// Replaces the native router and wakes timers that still follow its old
    /// partial input.
    ///
    /// ```zig
    /// state.replaceRouter(io, replacement);
    /// ```
    pub fn replaceRouter(state: *State, io: Io, replacement: Router) void {
        const prefix_was_pending = state.router.prefixPending();
        var inherited = replacement;
        inherited.inheritPhysicalLeases(&state.router);
        state.router = inherited;
        if (prefix_was_pending != state.router.prefixPending()) {
            state.presentation_revision +%= 1;
        }
        _ = state.input_timeout.update(io, null);
        _ = state.binding_timeout.update(io, null);
    }

    /// Returns the revision of visible host-input routing state.
    ///
    /// ```zig
    /// const revision = state.presentationVersion();
    /// ```
    pub fn presentationVersion(state: *const State) u64 {
        return state.presentation_revision;
    }

    /// Projects prefix help from the effective router without exposing its
    /// matching state to the presenter.
    ///
    /// ```zig
    /// const mode = state.statusMode(copy_mode_active);
    /// ```
    pub fn statusMode(state: *const State, copy_mode_active: bool) widgets.status_bar.Mode {
        if (!state.router.prefixPending()) {
            return if (copy_mode_active) .copy else .normal;
        }

        const DescribedAction = struct {
            action: Action,
            label: []const u8,
        };
        const useful = [_]DescribedAction{
            .{ .action = .{ .split_pane = .horizontal }, .label = "split right" },
            .{ .action = .{ .split_pane = .vertical }, .label = "split down" },
            .{ .action = .new_tab, .label = "new tab" },
            .{ .action = .new_workspace, .label = "new workspace" },
            .{ .action = .rename_tab, .label = "rename tab" },
            .{ .action = .rename_workspace, .label = "rename workspace" },
            .{ .action = .close_pane, .label = "close pane" },
            .{ .action = .enter_copy_mode, .label = "copy mode" },
        };
        var hints: widgets.status_bar.Hints = .{};
        for (useful) |described| {
            const key = state.router.prefixedKeyForAction(described.action) orelse continue;

            hints.append(.{ .key = key, .label = described.label });
        }

        return .{ .prefix = hints };
    }
};

const Expiry = enum {
    input,
    binding,
};

/// Starts one TTY read when transport backpressure permits it.
///
/// ```zig
/// try host_inputs.scheduleRead(client);
/// ```
pub fn scheduleRead(client: *Client) !void {
    const state = &client.host_input;
    if (state.read_pending or runtime_transport.availableCapacity(client) == 0) {
        return;
    }

    state.read_pending = true;
    client.select.concurrent(.input, read, .{ client.io, state.file }) catch |err| {
        state.read_pending = false;

        return err;
    };
}

/// Releases one TTY read, routes its bytes and rearms input work.
///
/// ```zig
/// if (try host_inputs.handleRead(client, result)) return 0;
/// ```
pub fn handleRead(client: *Client, result: anyerror!Chunk) !bool {
    const state = &client.host_input;
    state.read_pending = false;
    const chunk = try result;
    if (chunk.len == 0) {
        return true;
    }

    client.presenter.noteInput(client_clock.monotonic(client.io));
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = state.router.prefixPending();
    const lease_overflows_before = state.router.leaseOverflowCount();
    const control = try state.router.feed(chunk.slice(), client_clock.monotonic(client.io), &handler);
    client.telemetry.metrics.key_lease_overflows +%= state.router.leaseOverflowCount() -% lease_overflows_before;
    if (control == .stop) {
        return true;
    }

    try finishRouting(client, prefix_was_pending);
    try scheduleRead(client);

    return false;
}

/// Releases and applies one escape-sequence deadline.
///
/// ```zig
/// if (try host_inputs.handleInputTimeout(client, result)) return 0;
/// ```
pub fn handleInputTimeout(client: *Client, result: anyerror!void) !bool {
    try client.host_input.input_timeout.complete(result);

    return expire(client, .input);
}

/// Releases and applies one partial-binding deadline.
///
/// ```zig
/// if (try host_inputs.handleBindingTimeout(client, result)) return 0;
/// ```
pub fn handleBindingTimeout(client: *Client, result: anyerror!void) !bool {
    try client.host_input.binding_timeout.complete(result);

    return expire(client, .binding);
}

fn expire(client: *Client, expiry: Expiry) !bool {
    const state = &client.host_input;
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = state.router.prefixPending();
    const control = switch (expiry) {
        .input => try state.router.expireInput(client_clock.monotonic(client.io), &handler),
        .binding => try state.router.expireBinding(client_clock.monotonic(client.io), &handler),
    };
    if (control == .stop) {
        return true;
    }

    try finishRouting(client, prefix_was_pending);

    return false;
}

fn finishRouting(client: *Client, prefix_was_pending: bool) !void {
    syncPrefixStatus(client, prefix_was_pending);
    try synchronizeTimers(client);
}

fn syncPrefixStatus(client: *Client, prefix_was_pending: bool) void {
    if (prefix_was_pending == client.host_input.router.prefixPending()) {
        return;
    }

    client.host_input.presentation_revision +%= 1;
}

fn synchronizeTimers(client: *Client) !void {
    try synchronizeInputTimeout(client);
    try synchronizeBindingTimeout(client);
}

fn synchronizeInputTimeout(client: *Client) !void {
    const scheduler = &client.host_input.input_timeout;
    switch (scheduler.update(client.io, client.host_input.router.inputDeadline())) {
        .idle, .retained => {},
        .schedule => client.select.concurrent(.input_timeout, deadline_timer.wait, .{
            client.io,
            scheduler,
        }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn synchronizeBindingTimeout(client: *Client) !void {
    const scheduler = &client.host_input.binding_timeout;
    switch (scheduler.update(client.io, client.host_input.router.bindingDeadline())) {
        .idle, .retained => {},
        .schedule => client.select.concurrent(.binding_timeout, deadline_timer.wait, .{
            client.io,
            scheduler,
        }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn read(io: Io, file: File) anyerror!Chunk {
    var chunk: Chunk = .{};
    chunk.len = @intCast(try file.readStreaming(io, &.{&chunk.bytes}));

    return chunk;
}

test "host input configuration owns router timeouts" {
    const prefix = try keybind.parseKey("ctrl+s");
    const router = try buildRouter(.{
        .prefix = prefix,
        .bindings = &.{},
        .escape_timeout_ns = 7,
        .sequence_timeout_ns = 11,
    });

    try std.testing.expectEqualDeep(prefix, router.prefix.?);
    try std.testing.expectEqual(@as(u64, 7), router.escape_timeout_ns);
    try std.testing.expectEqual(@as(u64, 11), router.sequence_timeout_ns);
}

test "router replacement clears obsolete deadlines and visible prefix state" {
    const io = std.testing.io;
    var original = try buildRouter(.{
        .prefix = keybind.default_prefix,
        .bindings = &.{},
        .escape_timeout_ns = 25,
        .sequence_timeout_ns = 100,
    });
    original.prefix_pending = true;
    const replacement = try buildRouter(.{
        .prefix = try keybind.parseKey("ctrl+s"),
        .bindings = &.{},
        .escape_timeout_ns = 5,
        .sequence_timeout_ns = 20,
    });
    var state: State = .{
        .file = undefined,
        .router = original,
        .input_timeout = .{ .pending = true },
        .binding_timeout = .{ .pending = true },
    };

    state.replaceRouter(io, replacement);

    try std.testing.expect(state.input_timeout.pending);
    try std.testing.expect(state.binding_timeout.pending);
    try std.testing.expectEqual(std.math.maxInt(u64), state.input_timeout.deadline_ns.load(.acquire));
    try std.testing.expectEqual(std.math.maxInt(u64), state.binding_timeout.deadline_ns.load(.acquire));
    try std.testing.expectEqual(@as(u64, 5), state.router.escape_timeout_ns);
    try std.testing.expectEqual(@as(u64, 20), state.router.sequence_timeout_ns);
    try std.testing.expectEqual(@as(u64, 1), state.presentationVersion());
}

test "prefix status uses only the effective host input router" {
    const prefix = try keybind.parseKey("ctrl+s");
    const suffix = try keybind.parseKey("t");
    const binding = try lua_config.ConfiguredBinding.init(&.{ prefix, suffix }, .new_tab);
    var router = try Router.initWithPrefix(&.{binding}, prefix);
    router.prefix_pending = true;
    const state: State = .{ .file = undefined, .router = router };

    const mode = state.statusMode(false);
    try std.testing.expect(mode == .prefix);
    try std.testing.expectEqual(@as(u8, 1), mode.prefix.len);
    try std.testing.expectEqualDeep(suffix, mode.prefix.items[0].key);
    try std.testing.expectEqualStrings("new tab", mode.prefix.items[0].label);
}
