//! Owns one client's host-TTY read, native router and replaceable deadlines.

const GenericRouter = @import("../../../input/GenericRouter.zig").Type;
const Action = @import("telar-client").Action;
const model = @import("../../../config/model.zig");
const std = @import("std");
const max_encoded_bytes = @import("telar-client").max_encoded_bytes;
const Config = @import("Config.zig");
const default_bindings = @import("../../../config/default_bindings.zig");
const Client = @import("../../Client.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const mark_module = @import("telar-core").mark;
const Chunk = @import("Chunk.zig");
const InputHandler = @import("../../resources/InputHandler.zig");
const monotonic_module = @import("telar-client").monotonic;
const wait_module = @import("telar-client").wait;
const parseKey_module = @import("telar-client").parseKey;
const default_prefix_module = @import("telar-client").default_prefix;
const State = @import("State.zig");

pub const chunk_size = 4096;
const held_binding_bytes = 128;

pub const Router = GenericRouter(
    Action,
    .{
        .max_bindings = model.max_bindings,
        .max_keys = model.max_binding_keys,
        .input_capacity = chunk_size,
        .held_capacity = held_binding_bytes,
    },
);

comptime {
    std.debug.assert(chunk_size <= max_encoded_bytes);
}

/// Compiles an owned, allocation-free router from validated configuration.
///
/// ```zig
/// const router = try buildRouter(config);
/// ```
pub fn buildRouter(config: Config) !Router {
    const resolved = try default_bindings.resolve(config.prefix, config.bindings);
    var router = try Router.initWithPrefix(resolved.slice(), config.prefix);
    router.escape_timeout_ns = config.escape_timeout_ns;
    router.sequence_timeout_ns = config.sequence_timeout_ns;

    return router;
}

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
    client.select.concurrent(.input, read, .{ client.io, state.file, &state.chunk }) catch |err| {
        state.read_pending = false;

        return err;
    };
}

/// Releases one TTY read that completed into the state-owned chunk, routes
/// its bytes and rearms input work.
///
/// ```zig
/// if (try host_inputs.handleOwnedRead(client, result)) return 0;
/// ```
pub fn handleOwnedRead(client: *Client, result: anyerror!u16) !bool {
    mark_module(client.io, .client_input);
    const state = &client.host_input;
    state.read_pending = false;
    state.chunk.len = try result;
    return routeChunk(client);
}

/// Routes one caller-provided chunk as if the TTY read had produced it.
///
/// ```zig
/// if (try host_inputs.handleRead(client, chunk)) return 0;
/// ```
pub fn handleRead(client: *Client, result: anyerror!Chunk) !bool {
    const state = &client.host_input;
    state.read_pending = false;
    state.chunk = try result;
    return routeChunk(client);
}

fn routeChunk(client: *Client) !bool {
    const state = &client.host_input;
    const chunk = &state.chunk;
    if (chunk.len == 0) {
        return true;
    }

    if (client.startup.holdsInput()) {
        var handler: InputHandler = .{ .client = client };
        try state.startup_input.feed(chunk.slice(), &handler);
        try scheduleRead(client);
        return false;
    }

    const stop = try routeBytes(client, chunk.slice());
    if (!stop) {
        try scheduleRead(client);
    }

    return stop;
}

/// Replays early input only after the runtime has supplied the active pane.
/// Example: `if (try replayStartup(client)) detachClient();`.
pub fn replayStartup(client: *Client) !bool {
    const bytes = try client.host_input.startup_input.finish();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + chunk_size, bytes.len);
        if (try routeBytes(client, bytes[offset..end])) {
            return true;
        }

        offset = end;
    }

    return false;
}

fn routeBytes(client: *Client, bytes: []const u8) !bool {
    const state = &client.host_input;
    client.presenter.noteInput(monotonic_module(client.io));
    var handler: InputHandler = .{ .client = client };
    const prefix_was_pending = state.router.prefixPending();
    const lease_overflows_before = state.router.leaseOverflowCount();
    const control = try state.router.feed(.{
        .bytes = bytes,
        .now_ns = monotonic_module(client.io),
    }, &handler);
    client.telemetry.metrics.key_lease_overflows +%= state.router.leaseOverflowCount() -% lease_overflows_before;
    if (control == .stop) {
        return true;
    }

    try finishRouting(client, prefix_was_pending);

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
        .input => try state.router.expireInput(monotonic_module(client.io), &handler),
        .binding => try state.router.expireBinding(monotonic_module(client.io), &handler),
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
        .schedule => client.select.concurrent(.input_timeout, wait_module, .{
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
        .schedule => client.select.concurrent(.binding_timeout, wait_module, .{
            client.io,
            scheduler,
        }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn read(io: std.Io, file: std.Io.File, chunk: *Chunk) anyerror!u16 {
    const length = try file.readStreaming(io, &.{&chunk.bytes});
    mark_module(io, .host_read);
    return @intCast(length);
}

test "host input configuration owns router timeouts" {
    const prefix = try parseKey_module("ctrl+s");
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
        .prefix = default_prefix_module,
        .bindings = &.{},
        .escape_timeout_ns = 25,
        .sequence_timeout_ns = 100,
    });
    original.prefix_pending = true;
    const replacement = try buildRouter(.{
        .prefix = try parseKey_module("ctrl+s"),
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
    const prefix = try parseKey_module("ctrl+s");
    const suffix = try parseKey_module("t");
    const binding = try model.ConfiguredBinding.init(&.{ prefix, suffix }, .new_tab);
    var router = try Router.initWithPrefix(&.{binding}, prefix);
    router.prefix_pending = true;
    const state: State = .{ .file = undefined, .router = router };

    const mode = state.statusMode(false);
    try std.testing.expect(mode == .prefix);
    try std.testing.expectEqual(@as(u8, 1), mode.prefix.len);
    try std.testing.expectEqualDeep(suffix, mode.prefix.items[0].key);
    try std.testing.expectEqualStrings("new tab", mode.prefix.items[0].label);
}
