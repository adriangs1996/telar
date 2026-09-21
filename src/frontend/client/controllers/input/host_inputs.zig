//! Owns one client's host-TTY read, native router and replaceable deadlines.

const TerminalClient = @import("../../TerminalClient.zig");
const host = TerminalClient.of;
const GenericRouter = @import("../../../input/GenericRouter.zig").Type;
const Action = @import("telar-client").Action;
const model = @import("telar-client").config_model;
const std = @import("std");
const max_encoded_bytes = @import("telar-client").max_encoded_bytes;
const Config = @import("telar-client").RouterConfig;
const default_bindings = @import("telar-client").default_bindings;
const Client = @import("telar-client").AttachedClient;
const runtime_transport = @import("telar-client").runtime_io;
const mark_module = @import("telar-core").mark;
const Chunk = @import("Chunk.zig");
const key_routing = @import("telar-client").operations.key_routing;
const KeyType = @import("telar-client").Key;
const paste_routing = @import("telar-client").operations.paste_routing;
const term = @import("../../../presentation/screen_support.zig");
const MouseType = @import("telar-client").Mouse;
const pointer_routing = @import("telar-client").operations.pointer_routing;
const host_capabilities = @import("../host/host_capabilities.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const presentation_lifecycle = @import("../../presentation/presentation_lifecycle.zig");
const action_routing = @import("telar-client").operations.action_routing;
const ControlType = @import("telar-client").Control;
const tab_drag = @import("tab_drag.zig");
const monotonic_module = @import("telar-client").monotonic;
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
    const state = &host(client).host_input;
    if (state.read_pending or runtime_transport.availableCapacity(client) == 0) {
        return;
    }

    state.read_pending = true;
    host(client).inbox.start(.input, .{ read, .{ client.io, state.file, &state.chunk } }) catch |err| {
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
    const state = &host(client).host_input;
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
    const state = &host(client).host_input;
    state.read_pending = false;
    state.chunk = try result;
    return routeChunk(client);
}

fn routeChunk(client: *Client) !bool {
    const state = &host(client).host_input;
    const chunk = &state.chunk;
    if (chunk.len == 0) {
        return true;
    }

    if (client.startup.holdsInput()) {
        var early = chunk.slice();
        while (try state.startup_input.next(&early)) |response| {
            try terminalResponse(client, response);
        }
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
    const bytes = try host(client).host_input.startup_input.finish();
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
    const state = &host(client).host_input;
    client.presentation.noteInput(monotonic_module(client.io));
    const prefix_was_pending = state.router.prefixPending();
    const lease_overflows_before = state.router.leaseOverflowCount();
    const control = try feed(client, .{
        .bytes = bytes,
        .now_ns = monotonic_module(client.io),
    });
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
    try host(client).host_input.input_timeout.complete(result);

    return expire(client, .input);
}

/// Releases and applies one partial-binding deadline.
///
/// ```zig
/// if (try host_inputs.handleBindingTimeout(client, result)) return 0;
/// ```
pub fn handleBindingTimeout(client: *Client, result: anyerror!void) !bool {
    try host(client).host_input.binding_timeout.complete(result);

    return expire(client, .binding);
}

fn expire(client: *Client, expiry: Expiry) !bool {
    const state = &host(client).host_input;
    const prefix_was_pending = state.router.prefixPending();
    const control = switch (expiry) {
        .input => if (state.router.expireInput(monotonic_module(client.io))) |event|
            try decoded(client, event, monotonic_module(client.io))
        else
            .continue_routing,
        .binding => try applyDecision(client, state.router.expireBinding(monotonic_module(client.io))),
    };
    if (control == .stop) {
        state.router.clear();
        return true;
    }

    try finishRouting(client, prefix_was_pending);

    return false;
}

/// Routes one borrowed byte slice after the native router has replayed it.
///
/// ```zig
/// try host_inputs.forward(client, bytes);
/// ```
pub fn forward(client: *Client, bytes: []const u8) !void {
    if (std.mem.eql(u8, bytes, "\x1b[O")) {
        _ = tab_drag.cancel(client);
    }

    if (std.mem.eql(u8, bytes, "\x1b") and tab_drag.cancel(client)) {
        return;
    }

    _ = try key_routing.apply(client, .{ .bytes = bytes });
}

/// Routes one semantic host key after native binding resolution.
///
/// ```zig
/// try host_inputs.key(client, pressed);
/// ```
pub fn key(client: *Client, value: KeyType) !void {
    const escape_key = &host(client).view.tab_drag.escape_key;
    if (value.physical) |physical| {
        if (escape_key.*) |owner| {
            if (owner.eql(physical)) {
                if (value.phase == .release) {
                    escape_key.* = null;
                }

                return;
            }
        }
    }

    if (value.code == .escape and tab_drag.cancel(client)) {
        if (value.phase == .press) {
            escape_key.* = value.physical;
        }

        return;
    }

    _ = try key_routing.apply(client, .{ .key = value });
}

pub fn mouse(client: *Client, event: MouseType) !void {
    if (try tab_drag.retained(client, event)) {
        return;
    }

    _ = try pointer_routing.apply(client, event);
}

/// Reconciles one host-terminal response without forwarding it: capability
/// probe replies update the host model, and Kitty replies for pane images
/// tell the graphics store whether the host took a shared object.
///
/// ```zig
/// try host_inputs.terminalResponse(client, response);
/// ```
pub fn terminalResponse(client: *Client, response: term.Event.TerminalResponse) !void {
    _ = try host_capabilities.observe(client, response);
    switch (response) {
        .kitty_graphics => |reply| {
            if (!kitty_delivery.noteHostReply(&host(client).graphics_store, reply.image_id, reply.supported)) {
                return;
            }
            try runtime_transport.flushGraphicsCredits(client);
            try presentation_lifecycle.observe(client);
        },
        else => {},
    }
}

/// Execute each decision before decoding the next event, so later keys observe
/// changes to focus and modal state. Example: `_ = try host_inputs.feed(client, input);`
pub fn feed(client: *Client, input: Router.Feed) !ControlType {
    const router = &host(client).host_input.router;
    var remaining = input;
    while (router.next(&remaining)) |event| {
        if (try decoded(client, event, input.now_ns) == .stop) {
            router.clear();
            return .stop;
        }
    }
    return .continue_routing;
}

fn decoded(client: *Client, event: Router.Decoded, now_ns: u64) !ControlType {
    const router = &host(client).host_input.router;
    if (event.paste_content) {
        _ = try paste_routing.content(client, event.raw);
        return .continue_routing;
    }
    switch (event.event) {
        .key => |value| {
            errdefer router.eventFailed(value);
            return applyDecision(client, router.routeEvent(.{ .key = value, .raw = event.raw, .now_ns = now_ns }, .{
                .captures_keys = key_routing.captures(client),
                .repeat_policy = if (router.repeatAction()) |held| action_routing.repeatPolicy(client, held) else null,
            }));
        },
        .mouse => |value| {
            router.cancelSequence();
            try mouse(client, value);
        },
        .terminal_response => |value| {
            router.observeHostResponse();
            try terminalResponse(client, value);
        },
        .paste_start => {
            _ = try applyDecision(client, router.interrupt());
            _ = try paste_routing.start(client);
        },
        .paste_end => {
            _ = try applyDecision(client, router.interrupt());
            _ = try paste_routing.finish(client);
        },
        .incomplete => {
            _ = try applyDecision(client, router.interrupt());
        },
    }
    return .continue_routing;
}

fn applyDecision(client: *Client, decision: Router.Decision) !ControlType {
    const router = &host(client).host_input.router;
    switch (decision) {
        .forward => |value| try key(client, value.key),
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try key(client, held);
            }
            if (value.current_key) |current| {
                try key(client, current);
            }
        },
        .action => |request| {
            const control = try action_routing.apply(client, request.value);
            if (control == .continue_routing) {
                router.actionCompleted(request, action_routing.repeatPolicy(client, request.value));
            }
            return control;
        },
        .pending, .discard => {},
    }
    return .continue_routing;
}

fn finishRouting(client: *Client, prefix_was_pending: bool) !void {
    syncPrefixStatus(client, prefix_was_pending);
    try synchronizeTimers(client);
}

fn syncPrefixStatus(client: *Client, prefix_was_pending: bool) void {
    if (prefix_was_pending == host(client).host_input.router.prefixPending()) {
        return;
    }

    host(client).host_input.presentation_revision +%= 1;
}

fn synchronizeTimers(client: *Client) !void {
    try synchronizeInputTimeout(client);
    try synchronizeBindingTimeout(client);
}

fn synchronizeInputTimeout(client: *Client) !void {
    const scheduler = &host(client).host_input.input_timeout;
    switch (scheduler.update(client.io, host(client).host_input.router.inputDeadline())) {
        .idle, .retained => {},
        .schedule => client.timers.arm(.input, scheduler) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn synchronizeBindingTimeout(client: *Client) !void {
    const scheduler = &host(client).host_input.binding_timeout;
    switch (scheduler.update(client.io, host(client).host_input.router.bindingDeadline())) {
        .idle, .retained => {},
        .schedule => client.timers.arm(.binding, scheduler) catch |err| {
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
