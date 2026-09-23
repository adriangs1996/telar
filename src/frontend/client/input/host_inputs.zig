//! Owns one client's host-TTY read, native router and replaceable deadlines.

const data = @import("model");
const client_module = @import("telar-client");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const GenericRouter = @import("../../input/GenericRouter.zig").Type;
const std = @import("std");
const Chunk = @import("Chunk.zig");
const term = @import("../../presentation/screen_support.zig");
const host_capabilities = @import("../host/host_capabilities.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const tab_drag = @import("tab_drag.zig");
const HostInput = @import("HostInput.zig");

pub const chunk_size = 4096;
const held_binding_bytes = 128;

pub const Router = GenericRouter(
    data.Action,
    .{
        .max_bindings = data.config_values.max_bindings,
        .max_keys = data.config_values.max_binding_keys,
        .input_capacity = chunk_size,
        .held_capacity = held_binding_bytes,
    },
);

comptime {
    std.debug.assert(chunk_size <= data.input_limits.max_encoded_bytes);
}

/// Compiles an owned, allocation-free router from validated configuration.
///
/// ```zig
/// const router = try buildRouter(config);
/// ```
pub fn buildRouter(config: client_module.RouterConfig) !Router {
    const resolved = try client_module.default_bindings.resolve(config.prefix, config.bindings);
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
/// try host_inputs.scheduleRead(terminal);
/// ```
pub fn scheduleRead(terminal: *TerminalClient) !void {
    const client = &terminal.app;

    const state = &terminal.host_input;
    if (state.read_pending or client.model.to_runtime.availableCapacity() == 0) {
        return;
    }

    state.read_pending = true;
    terminal.inbox.start(.input, .{ read, .{ client.io, state.file, &state.chunk } }) catch |err| {
        state.read_pending = false;

        return err;
    };
}

/// Releases one TTY read that completed into the state-owned chunk, routes
/// its bytes and rearms input work.
///
/// ```zig
/// if (try host_inputs.handleOwnedRead(terminal, result)) return 0;
/// ```
pub fn handleOwnedRead(terminal: *TerminalClient, result: anyerror!u16) !bool {
    const client = &terminal.app;

    core.mark(client.io, .client_input);
    const state = &terminal.host_input;
    state.read_pending = false;
    state.chunk.len = try result;
    return routeChunk(terminal);
}

/// Routes one caller-provided chunk as if the TTY read had produced it.
///
/// ```zig
/// if (try host_inputs.handleRead(terminal, chunk)) return 0;
/// ```
pub fn handleRead(terminal: *TerminalClient, result: anyerror!Chunk) !bool {
    const state = &terminal.host_input;
    state.read_pending = false;
    state.chunk = try result;
    return routeChunk(terminal);
}

fn routeChunk(terminal: *TerminalClient) !bool {
    const client = &terminal.app;

    const state = &terminal.host_input;
    const chunk = &state.chunk;
    if (chunk.len == 0) {
        return true;
    }

    if (client.model.startup.holdsInput()) {
        var early = chunk.slice();
        while (try state.startup_input.next(&early)) |response| {
            try terminalResponse(terminal, response);
        }
        try scheduleRead(terminal);
        return false;
    }

    const stop = try routeBytes(terminal, chunk.slice());
    if (!stop) {
        try scheduleRead(terminal);
    }

    return stop;
}

/// Replays early input only after the runtime has supplied the active pane.
/// Example: `if (try replayStartup(terminal)) detachClient();`.
pub fn replayStartup(terminal: *TerminalClient) !bool {
    const bytes = try terminal.host_input.startup_input.finish();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + chunk_size, bytes.len);
        if (try routeBytes(terminal, bytes[offset..end])) {
            return true;
        }

        offset = end;
    }

    return false;
}

fn routeBytes(terminal: *TerminalClient, bytes: []const u8) !bool {
    const client = &terminal.app;

    const state = &terminal.host_input;
    terminal.presenter.noteInput(client_module.monotonic(client.io));
    const prefix_was_pending = state.router.prefixPending();
    const lease_overflows_before = state.router.leaseOverflowCount();
    const control = try feed(terminal, .{
        .bytes = bytes,
        .now_ns = client_module.monotonic(client.io),
    });
    client.telemetry.metrics.key_lease_overflows +%= state.router.leaseOverflowCount() -% lease_overflows_before;
    if (control == .stop) {
        return true;
    }

    try finishRouting(terminal, prefix_was_pending);

    return false;
}

/// Releases and applies one escape-sequence deadline.
///
/// ```zig
/// if (try host_inputs.handleInputTimeout(terminal, result)) return 0;
/// ```
pub fn handleInputTimeout(terminal: *TerminalClient, result: anyerror!void) !bool {
    try terminal.host_input.input_timeout.complete(result);

    return expire(terminal, .input);
}

/// Releases and applies one partial-binding deadline.
///
/// ```zig
/// if (try host_inputs.handleBindingTimeout(terminal, result)) return 0;
/// ```
pub fn handleBindingTimeout(terminal: *TerminalClient, result: anyerror!void) !bool {
    try terminal.host_input.binding_timeout.complete(result);

    return expire(terminal, .binding);
}

fn expire(terminal: *TerminalClient, expiry: Expiry) !bool {
    const client = &terminal.app;

    const state = &terminal.host_input;
    const prefix_was_pending = state.router.prefixPending();
    const control = switch (expiry) {
        .input => if (state.router.expireInput(client_module.monotonic(client.io))) |event|
            try decoded(terminal, event, client_module.monotonic(client.io))
        else
            .continue_routing,
        .binding => try applyDecision(terminal, state.router.expireBinding(client_module.monotonic(client.io))),
    };
    if (control == .stop) {
        state.router.clear();
        return true;
    }

    try finishRouting(terminal, prefix_was_pending);

    return false;
}

/// Routes one borrowed byte slice after the native router has replayed it.
///
/// ```zig
/// try host_inputs.forward(terminal, bytes);
/// ```
pub fn forward(terminal: *TerminalClient, bytes: []const u8) !void {
    const client = &terminal.app;

    if (std.mem.eql(u8, bytes, "\x1b[O")) {
        _ = tab_drag.cancel(terminal);
    }

    if (std.mem.eql(u8, bytes, "\x1b") and tab_drag.cancel(terminal)) {
        return;
    }

    _ = try client.routeKeyInput(
        .{
            .bytes = bytes,
        },
    );
}

/// Routes one semantic host key after native binding resolution.
///
/// ```zig
/// try host_inputs.key(terminal, pressed);
/// ```
pub fn key(terminal: *TerminalClient, value: data.Key) !void {
    const client = &terminal.app;

    const escape_key = &terminal.view.tab_drag.escape_key;
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

    if (value.code == .escape and tab_drag.cancel(terminal)) {
        if (value.phase == .press) {
            escape_key.* = value.physical;
        }

        return;
    }

    _ = try client.routeKeyInput(
        .{
            .key = value,
        },
    );
}

pub fn mouse(terminal: *TerminalClient, event: data.Mouse) !void {
    const client = &terminal.app;

    if (try tab_drag.retained(terminal, event)) {
        return;
    }

    _ = try client_module.pointer_routing.apply(client, event);
}

/// Reconciles one host-terminal response without forwarding it: capability
/// probe replies update the host model, and Kitty replies for pane images
/// tell the graphics store whether the host took a shared object.
///
/// ```zig
/// try host_inputs.terminalResponse(terminal, response);
/// ```
pub fn terminalResponse(terminal: *TerminalClient, response: term.Event.TerminalResponse) !void {
    const client = &terminal.app;

    _ = try host_capabilities.observe(terminal, response);
    switch (response) {
        .kitty_graphics => |reply| {
            if (!kitty_delivery.noteHostReply(&terminal.graphics_store, reply.image_id, reply.supported)) {
                return;
            }
            try client.flushGraphicsCredits();
            try presentation_lifecycle.observe(terminal);
        },
        else => {},
    }
}

/// Execute each decision before decoding the next event, so later keys observe
/// changes to focus and modal state. Example: `_ = try host_inputs.feed(terminal, input);`
pub fn feed(terminal: *TerminalClient, input: Router.Feed) !data.KeybindControl {
    const router = &terminal.host_input.router;
    var remaining = input;
    while (router.next(&remaining)) |event| {
        if (try decoded(terminal, event, input.now_ns) == .stop) {
            router.clear();
            return .stop;
        }
    }
    return .continue_routing;
}

fn decoded(terminal: *TerminalClient, event: Router.Decoded, now_ns: u64) !data.KeybindControl {
    const client = &terminal.app;

    const router = &terminal.host_input.router;
    if (event.paste_content) {
        _ = try client_module.paste_routing.content(client, event.raw);
        return .continue_routing;
    }
    switch (event.event) {
        .key => |value| {
            errdefer router.eventFailed(value);
            return applyDecision(
                terminal,
                router.routeEvent(
                    .{
                        .key = value,
                        .raw = event.raw,
                        .now_ns = now_ns,
                    },
                    .{
                        .captures_keys = data.key_routing.captures(client.keyRoutingAuthority()),
                        .repeat_policy = if (router.repeatAction()) |held| client_module.repeatPolicy(held, client.repeatPane()) else null,
                    },
                ),
            );
        },
        .mouse => |value| {
            router.cancelSequence();
            try mouse(terminal, value);
        },
        .terminal_response => |value| {
            router.observeHostResponse();
            try terminalResponse(terminal, value);
        },
        .paste_start => {
            _ = try applyDecision(terminal, router.interrupt());
            _ = try client_module.paste_routing.start(client);
        },
        .paste_end => {
            _ = try applyDecision(terminal, router.interrupt());
            _ = try client_module.paste_routing.finish(client);
        },
        .incomplete => {
            _ = try applyDecision(terminal, router.interrupt());
        },
    }
    return .continue_routing;
}

fn applyDecision(terminal: *TerminalClient, decision: Router.Decision) !data.KeybindControl {
    const client = &terminal.app;

    const router = &terminal.host_input.router;
    switch (decision) {
        .forward => |value| try key(terminal, value.key),
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try key(terminal, held);
            }
            if (value.current_key) |current| {
                try key(terminal, current);
            }
        },
        .action => |request| {
            const control = try client.executeAction(request.value, .binding);
            if (control == .continue_routing) {
                router.actionCompleted(request, client_module.repeatPolicy(request.value, client.repeatPane()));
            }
            return control;
        },
        .pending, .discard => {},
    }
    return .continue_routing;
}

fn finishRouting(terminal: *TerminalClient, prefix_was_pending: bool) !void {
    syncPrefixStatus(terminal, prefix_was_pending);
    try synchronizeTimers(terminal);
}

fn syncPrefixStatus(terminal: *TerminalClient, prefix_was_pending: bool) void {
    if (prefix_was_pending == terminal.host_input.router.prefixPending()) {
        return;
    }

    terminal.host_input.presentation_revision +%= 1;
}

fn synchronizeTimers(terminal: *TerminalClient) !void {
    try synchronizeInputTimeout(terminal);
    try synchronizeBindingTimeout(terminal);
}

fn synchronizeInputTimeout(terminal: *TerminalClient) !void {
    const client = &terminal.app;

    const scheduler = &terminal.host_input.input_timeout;
    switch (scheduler.update(client.io, terminal.host_input.router.inputDeadline())) {
        .idle, .retained => {},
        .schedule => terminal.inbox.start(.input_timeout, .{ client_module.wait, .{ client.io, scheduler } }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn synchronizeBindingTimeout(terminal: *TerminalClient) !void {
    const client = &terminal.app;

    const scheduler = &terminal.host_input.binding_timeout;
    switch (scheduler.update(client.io, terminal.host_input.router.bindingDeadline())) {
        .idle, .retained => {},
        .schedule => terminal.inbox.start(.binding_timeout, .{ client_module.wait, .{ client.io, scheduler } }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

fn read(io: std.Io, file: std.Io.File, chunk: *Chunk) anyerror!u16 {
    const length = try file.readStreaming(io, &.{&chunk.bytes});
    core.mark(io, .host_read);
    return @intCast(length);
}

test "host input configuration owns router timeouts" {
    const prefix = try data.chord.parseKey("ctrl+s");
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
        .prefix = data.keybind.default_prefix,
        .bindings = &.{},
        .escape_timeout_ns = 25,
        .sequence_timeout_ns = 100,
    });
    original.prefix_pending = true;
    const replacement = try buildRouter(.{
        .prefix = try data.chord.parseKey("ctrl+s"),
        .bindings = &.{},
        .escape_timeout_ns = 5,
        .sequence_timeout_ns = 20,
    });
    var state: HostInput = .{
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
    const prefix = try data.chord.parseKey("ctrl+s");
    const suffix = try data.chord.parseKey("t");
    const binding = try data.config_values.ConfiguredBinding.init(&.{ prefix, suffix }, .new_tab);
    var router = try Router.initWithPrefix(&.{binding}, prefix);
    router.prefix_pending = true;
    const state: HostInput = .{ .file = undefined, .router = router };

    const mode = state.statusMode(false);
    try std.testing.expect(mode == .prefix);
    try std.testing.expectEqual(@as(u8, 1), mode.prefix.len);
    try std.testing.expectEqualDeep(suffix, mode.prefix.items[0].key);
    try std.testing.expectEqualStrings("new tab", mode.prefix.items[0].label);
}
