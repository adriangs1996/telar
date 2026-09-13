const std = @import("std");
const client = @import("telar-client");
const Event = @import("native/native.zig").InputEvent;
const Item = @import("input_item.zig").Item;
const core = @import("telar-core");
const routing = @import("input/router.zig");
const InputHandler = @import("input/InputHandler.zig");
const PointerRouting = @import("input/PointerRouting.zig");
const ReleaseRecovery = @import("input/ReleaseRecovery.zig");
const Input = @This();

pub const max_paste_bytes = 64 * 1024;
const capacity = 1024;
items: [capacity]Item = undefined,
head: usize = 0,
len: usize = 0,
router: routing.Type = defaultRouter(),
binding_timeout: client.Scheduler = .{},
pointer: PointerRouting = .{},
stopped: bool = false,
presentation_revision: u64 = 0,
recovery: ReleaseRecovery = .{},

/// Example: `var input = try Input.init(config);`
pub fn init(config: client.RouterConfig) !Input {
    return .{ .router = try routing.build(config) };
}

/// Replaces bindings without transferring held keys to their new meanings.
/// Example: `input.adopt(app, config);`
pub fn adopt(input: *Input, app: *client.AttachedClient, config: client.RouterConfig) void {
    var replacement = routing.build(config) catch unreachable;
    replacement.inheritPhysicalLeases(&input.router);
    input.router = replacement;
    input.presentation_revision +%= 1;
    _ = input.binding_timeout.update(app.io, null);
}

/// Example: `input.setGeometry(renderer.origin, size);`
pub fn setGeometry(input: *Input, origin: [2]u32, size: core.TerminalSize) void {
    input.pointer.configure(origin, size);
}

/// Reserves one control slot to finish gestures even when ordinary input is
/// saturated. Example: `try input.cancelPointer(app);`
pub fn cancelPointer(input: *Input, app: *client.AttachedClient) !void {
    input.scheduleRecovery();
    try input.drain(app);
    try app.host_input_source.resumeRead();
}

/// Prompt replay contains UTF-8 text, never a terminal escape stream.
/// Example: `try Input.routePromptBytes(app, bytes);`
pub fn routePromptBytes(app: *client.AttachedClient, bytes: []const u8) !void {
    _ = try client.controllers.name_prompts.handleInput(app, .{ .paste_text = bytes });
}

/// Example: `try input.expire(app, result);`
pub fn expire(input: *Input, app: *client.AttachedClient, result: anyerror!void) !void {
    try input.binding_timeout.complete(result);
    var handler: InputHandler = .{ .app = app };
    const pending = input.router.prefixPending();
    input.stopped = try input.router.expireBinding(client.monotonic(app.io), &handler) == .stop;
    try input.finish(app, pending);
}

/// Example: `const mode = input.statusMode(app.model.copyModeActive());`
pub fn statusMode(input: *const Input, copy_mode_active: bool) client.Mode {
    if (!input.router.prefixPending()) {
        return if (copy_mode_active) .copy else .normal;
    }

    var hints: client.Hints = .{};
    const actions = [_]client.Action{ .{ .split_pane = .horizontal }, .{ .split_pane = .vertical }, .new_tab, .new_workspace, .rename_tab, .rename_workspace, .close_pane, .enter_copy_mode };
    const labels = [_][]const u8{ "split right", "split down", "new tab", "new workspace", "rename tab", "rename workspace", "close pane", "copy mode" };
    for (actions, labels) |action, label| {
        const key = input.router.prefixedKeyForAction(action) orelse continue;
        hints.append(.{ .key = key, .label = label });
    }

    return .{ .prefix = hints };
}

/// Copies borrowed native input before returning to the platform callback.
/// A whole paste is admitted or rejected. Example: `try input.accept(event);`
pub fn accept(input: *Input, event: Event) !void {
    if (event.len > max_paste_bytes) {
        return error.InputTooLarge;
    }

    if ((event.len != 0 and event.text == null) or event.mods > (if (event.kind == 6) @as(u32, 15) else 7) or event.phase < 1 or event.phase > 3 or event.physical > ReleaseRecovery.capacity) {
        return error.InvalidNativeInput;
    }

    if (event.kind == 6) {
        if (event.code < 1 or event.code > 7 or event.button > 2 or event.len != 0 or !std.math.isFinite(event.x) or !std.math.isFinite(event.y)) {
            return error.InvalidNativePointer;
        }

        input.reserve(1) catch |err| {
            if (event.code != 2 and event.code != 7) {
                return err;
            }

            input.scheduleRecovery();
            return;
        };
        input.push(.{ .pointer = input.pointer.sample(event) });
        return;
    }

    const text = if (event.text) |ptr| ptr[0..event.len] else "";
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    switch (event.kind) {
        1 => {
            const view = try std.unicode.Utf8View.init(text);
            var iterator = view.iterator();
            var count: usize = 0;
            while (iterator.nextCodepoint() != null) {
                count += 1;
            }

            input.reserve(count) catch |err| {
                if (count != 1 or event.phase != 3 or event.physical == 0) {
                    return err;
                }
            };
            iterator = view.iterator();
            while (iterator.nextCodepointSlice()) |bytes| {
                var key: client.Key = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = @enumFromInt(event.phase) };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                if (count == 1 and event.physical != 0) {
                    key.physical = .{ .value = event.physical };
                }

                try input.pushKey(key);
            }
        },
        2 => {
            if (text.len == 0) {
                return;
            }

            var offset: usize = 0;
            var chunks: usize = 0;
            while (offset < text.len) {
                offset += pasteChunkSize(text[offset..]);
                chunks += 1;
            }

            try input.reserve(chunks + 2);
            input.push(.paste_start);
            offset = 0;
            while (offset < text.len) {
                const count = pasteChunkSize(text[offset..]);
                var chunk: @import("PasteChunk.zig") = .{ .len = @intCast(count) };
                @memcpy(chunk.bytes[0..count], text[offset..][0..count]);
                input.push(.{ .paste_text = chunk });
                offset += count;
            }

            input.push(.paste_finish);
        },
        3 => {
            const codes = [_]client.Key.Code{ .enter, .tab, .backspace, .escape, .up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down };
            var key: client.Key = .{
                .code = if (event.code >= 1 and event.code <= codes.len) codes[event.code - 1] else return error.InvalidNativeKey,
                .mods = @bitCast(@as(u3, @truncate(event.mods))),
                .phase = if (event.phase >= 1 and event.phase <= 3) @enumFromInt(event.phase) else return error.InvalidNativeKey,
            };
            if (key.code == .tab and key.mods.shift and !key.mods.ctrl and !key.mods.alt) {
                key.code = .back_tab;
                key.mods.shift = false;
            }

            key.physical = if (event.physical == 0) null else .{ .value = event.physical };
            try input.pushKey(key);
        },
        4 => {
            var key: client.Key = .{
                .code = .{ .char = .{ .bytes = @splat(0), .len = 0 } },
                .mods = @bitCast(@as(u3, @truncate(event.mods))),
                .phase = if (event.phase >= 1 and event.phase <= 3) @enumFromInt(event.phase) else return error.InvalidNativeKey,
            };
            key.code.char.len = try std.unicode.utf8Encode(std.math.cast(u21, event.code) orelse return error.InvalidNativeKey, &key.code.char.bytes);
            key.physical = if (event.physical == 0) null else .{ .value = event.physical };
            if (key.mods.ctrl and key.code.char.len == 1) {
                key.code.char.bytes[0] = std.ascii.toLower(key.code.char.bytes[0]);
            }

            if (!key.mods.ctrl) {
                key.mods.shift = false;
            }

            try input.pushKey(key);
        },
        else => return error.InvalidNativeInput,
    }
}

/// Stops before the shared outbox fills, resuming on transport completion.
/// Example: `try input.drain(&gui.app);`
pub fn drain(input: *Input, app: *client.AttachedClient) !void {
    if (app.startup.holdsInput()) {
        return;
    }

    var budget = client.DrainBudget.begin(app.io, input.len + input.recovery.len);
    var handler: InputHandler = .{ .app = app };
    const pending = input.router.prefixPending();
    while (!input.stopped and input.len != 0 and client.runtime_io.availableCapacity(app) >= 4 and budget.take(app.io)) {
        app.presentation.noteInput(client.monotonic(app.io));
        const overflows = input.router.leaseOverflowCount();
        switch (input.items[input.head]) {
            .key => |key| input.stopped = try input.router.routeEvent(.{ .key = key, .raw = "", .now_ns = client.monotonic(app.io) }, &handler) == .stop,
            .paste_start => {
                try input.router.interrupt(&handler);
                _ = try client.controllers.paste_routing.start(app);
            },
            .paste_text => |*chunk| _ = try client.controllers.paste_routing.content(app, chunk.bytes[0..chunk.len]),
            .paste_finish => _ = try client.controllers.paste_routing.finish(app),
            .release_recovery => {
                if (!input.recovery.pointer_finished) {
                    try input.pointer.cancel(app);
                    handler.cancelPointer();
                    input.recovery.pointer_finished = true;
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                if (input.recovery.next()) |key| {
                    input.stopped = try input.router.routeEvent(.{ .key = key, .raw = "", .now_ns = client.monotonic(app.io) }, &handler) == .stop;
                    input.recovery.finish(key);
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                input.recovery.queued = false;
                input.recovery.pointer_finished = false;
            },
            .pointer => |event| {
                if (event.event.code <= 5) {
                    input.router.cancelSequence();
                }

                try input.pointer.apply(app, event);
            },
        }

        app.telemetry.metrics.key_lease_overflows +%= input.router.leaseOverflowCount() -% overflows;
        input.head = (input.head + 1) % capacity;
        input.len -= 1;
    }

    try input.finish(app, pending);
}

fn finish(input: *Input, app: *client.AttachedClient, pending: bool) !void {
    if (pending != input.router.prefixPending()) {
        input.presentation_revision +%= 1;
    }

    if (input.binding_timeout.update(app.io, input.router.bindingDeadline()) == .schedule) {
        app.timers.arm(.binding, &input.binding_timeout) catch |err| {
            input.binding_timeout.schedulingFailed();
            return err;
        };
    }
}

fn pasteChunkSize(text: []const u8) usize {
    if (text.len <= 256) {
        return text.len;
    }

    var count: usize = 256;
    while (text[count] & 0xc0 == 0x80) {
        count -= 1;
    }

    return count;
}

fn defaultRouter() routing.Type {
    @setEvalBranchQuota(100000);
    return routing.build(.{ .prefix = client.default_prefix, .bindings = &.{}, .escape_timeout_ns = 25 * std.time.ns_per_ms, .sequence_timeout_ns = std.time.ns_per_s }) catch unreachable;
}

fn reserve(input: *const Input, count: usize) !void {
    if (input.recovery.queued or count > (capacity - 1) -| input.len) {
        return error.NativeInputFull;
    }
}

fn pushKey(input: *Input, key: client.Key) !void {
    input.reserve(1) catch |err| {
        if (key.phase != .release or key.physical == null) {
            return err;
        }

        input.recovery.retain(key);
        input.scheduleRecovery();
        return;
    };

    input.push(.{ .key = key });
}

fn scheduleRecovery(input: *Input) void {
    input.pointer.invalidateGestures();
    if (input.recovery.queued) {
        return;
    }

    std.debug.assert(input.len < capacity);
    input.push(.release_recovery);
    input.recovery.queued = true;
}

fn push(input: *Input, item: Item) void {
    input.items[(input.head + input.len) % capacity] = item;
    input.len += 1;
}

test "native paste admission is atomic and owns the borrowed bytes" {
    var input: Input = .{};
    var bytes = [_]u8{'x'} ** 257;
    try input.accept(.{ .kind = 2, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'y');
    try std.testing.expectEqual(@as(usize, 4), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.items[1].paste_text.bytes[0]);
    input.len = capacity - 1;
    try std.testing.expectError(error.NativeInputFull, input.accept(.{ .kind = 2, .text = &bytes, .len = bytes.len }));
    try std.testing.expectEqual(capacity - 1, input.len);
}

test "native key normalization preserves configured Ctrl-Space Alt uppercase and back-tab" {
    var input: Input = .{};
    try input.accept(.{ .kind = 4, .code = ' ', .mods = 4, .physical = 50 });
    try input.accept(.{ .kind = 4, .code = 'B', .mods = 4 });
    try input.accept(.{ .kind = 4, .code = 'N', .mods = 3 });
    try input.accept(.{ .kind = 3, .code = 2, .mods = 1 });
    const expected = [_][]const u8{ "ctrl+space", "ctrl+b", "alt+N", "shift+tab" };
    for (expected, 0..) |name, index| {
        var key = input.items[index].key;
        key.physical = null;
        try std.testing.expectEqualDeep(try client.parseKey(name), key);
    }

    try std.testing.expectEqual(@as(u32, 50), input.items[0].key.physical.?.value);
}

test "native input rejects invalid pointer and key payloads atomically" {
    var input: Input = .{};
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 1, .x = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 8 }));
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 1, .button = 3 }));
    try std.testing.expectError(error.InvalidNativeInput, input.accept(.{ .kind = 4, .code = 'x', .mods = 8 }));
    try std.testing.expectError(error.InvalidNativeKey, input.accept(.{ .kind = 3, .code = 99 }));
    try std.testing.expectError(error.InvalidUtf8, input.accept(.{ .kind = 1, .text = "\xff", .len = 1 }));
    try std.testing.expectEqual(@as(usize, 0), input.len);
}

test "native paste chunks preserve UTF-8 scalar boundaries for prompt editing" {
    var input: Input = .{};
    const bytes = "a" ** 255 ++ "🌍" ++ "b" ** 255;
    try input.accept(.{ .kind = 2, .text = bytes.ptr, .len = bytes.len });
    var total: usize = 0;
    for (input.items[0..input.len]) |item| {
        switch (item) {
            .paste_text => |chunk| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(chunk.bytes[0..chunk.len]));
                total += chunk.len;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(bytes.len, total);
}
