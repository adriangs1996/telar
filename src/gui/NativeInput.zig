const std = @import("std");
const client = @import("telar-client");
const NativeEvent = @import("native/native.zig").InputEvent;
const Event = @import("input/event.zig").Event;
const decode_input = @import("native/decode_input.zig");
const Item = @import("input_item.zig").Item;
const core = @import("telar-core");
const routing = @import("input/router.zig");
const InputHandler = @import("input/InputHandler.zig");
const PointerRouting = @import("input/PointerRouting.zig");
const ReleaseRecovery = @import("input/ReleaseRecovery.zig");
const GuiClient = @import("GuiClient.zig");
const KeyInput = @import("input/KeyInput.zig");
const GenericEventPool = @import("input/GenericEventPool.zig").Type;
const Input = @This();

pub const max_paste_bytes = @import("input/event.zig").max_text_bytes;
const capacity = 1024;
items: [capacity]Item = undefined,
head: usize = 0,
len: usize = 0,
router: routing.Type = defaultRouter(),
binding_timeout: client.Scheduler = .{},
binding_target: ?@import("widgets/interaction/Id.zig") = null,
pointer: PointerRouting = .{},
stopped: bool = false,
presentation_revision: u64 = 0,
recovery: ReleaseRecovery = .{},
small_events: GenericEventPool(4096, 8) = .{},
large_events: GenericEventPool(max_paste_bytes, 2) = .{},
widget_paste: bool = false,
scroll_remainder: f64 = 0,
terminal_clipboard: @import("host/TerminalClipboard.zig") = .{},
clipboard_offset: ?usize = null,

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
    input.binding_target = null;
    input.presentation_revision +%= 1;
    _ = input.binding_timeout.update(app.io, null);
}

/// Cancels a partial chord and its original widget before input changes owner.
/// Held physical keys retain their leases. Example: `input.cancelBinding();`
pub fn cancelBinding(input: *Input) void {
    input.router.cancelSequence();
    input.binding_target = null;
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
    var handler: InputHandler = .{ .app = app, .widget_target = input.binding_target };
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
pub fn accept(input: *Input, event: NativeEvent) !void {
    try input.acceptEvent(try decode_input.decode(event));
}

/// Admits semantic input validated by the native decoder. Text and paste are
/// copied into the bounded queue. Focus belongs to the driver's ordered inbox.
/// Example: `try input.acceptEvent(try decode_input.decode(native_event));`
pub fn acceptEvent(input: *Input, event: Event) !void {
    switch (event) {
        .pointer => |pointer| {
            input.reserve(1) catch |err| {
                if (pointer.kind != .release and pointer.kind != .leave) {
                    return err;
                }

                input.scheduleRecovery();
                return;
            };
            input.push(.{ .pointer = input.pointer.sample(pointer) });
        },
        .text => |text| {
            if (text.target_id != 0 and text.phase == .release and text.physical != null) {
                var iterator = (try std.unicode.Utf8View.init(text.bytes)).iterator();
                const bytes = iterator.nextCodepointSlice() orelse return error.InvalidNativeInput;
                if (iterator.nextCodepointSlice() != null) {
                    return error.InvalidNativeInput;
                }

                var key: KeyInput = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = .release, .physical = text.physical, .target_id = text.target_id, .generation = text.generation };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                try input.pushKey(key, .key);
                return;
            }

            if (text.target_id != 0) {
                try input.reserve(1);
                input.push(.{ .owned_small = try input.small_events.admit(event) });
                return;
            }

            const view = try std.unicode.Utf8View.init(text.bytes);
            var iterator = view.iterator();
            var count: usize = 0;
            while (iterator.nextCodepoint() != null) {
                count += 1;
            }

            input.reserve(count) catch |err| {
                if (count != 1 or text.phase != .release or text.physical == null) {
                    return err;
                }
            };
            iterator = view.iterator();
            while (iterator.nextCodepointSlice()) |bytes| {
                var key: KeyInput = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = text.phase };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                if (count == 1) {
                    key.physical = text.physical;
                }

                try input.pushKey(key, .text);
            }
        },
        .paste => |text| {
            if (text.len > max_paste_bytes) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(text)) {
                return error.InvalidUtf8;
            }

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
        .key => |key| try input.pushKey(key, .key),
        .focus => return error.FocusRequiresHostDispatch,
        .scroll => |scroll| {
            try input.reserve(1);
            input.push(.{ .scroll = .{ .event = scroll, .geometry_revision = input.pointer.revision, .gesture_revision = input.pointer.gesture_revision } });
        },
        .clipboard => {
            try input.reserve(1);
            input.push(.{ .owned_large = try input.large_events.admit(event) });
        },
        .composition => |value| {
            if (value.cancel) {
                input.reserve(1) catch {
                    input.scheduleRecovery();
                    return;
                };

                input.push(.{ .composition_cancel = .{ .target_id = value.target_id, .generation = value.generation, .cancel = true } });
                return;
            }

            try input.reserve(1);
            input.push(.{ .owned_small = try input.small_events.admit(event) });
        },
        .accessibility, .delete_surrounding => {
            try input.reserve(1);
            input.push(.{ .owned_small = try input.small_events.admit(event) });
        },
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
    const gui = GuiClient.of(app);
    const pending = input.router.prefixPending();
    while (!input.stopped and input.len != 0 and client.runtime_io.availableCapacity(app) >= 4 and budget.take(app.io)) {
        app.presentation.noteInput(client.monotonic(app.io));
        const overflows = input.router.leaseOverflowCount();
        switch (input.items[input.head]) {
            .key => |key| try input.dispatchKey(&handler, key),
            .text => |*text| {
                if (!try gui.widgetInput(.{ .text = text.text() })) {
                    input.stopped = try input.router.routeEvent(.{ .key = text.key(), .raw = "", .now_ns = client.monotonic(app.io) }, &handler) == .stop;
                }
            },
            .paste_start => {
                var replay: InputHandler = .{ .app = app, .widget_target = input.binding_target };
                try input.router.interrupt(&replay);
                input.widget_paste = try gui.beginWidgetPaste();
                if (!input.widget_paste) {
                    _ = try client.controllers.paste_routing.start(app);
                }
            },
            .paste_text => |*chunk| {
                if (input.widget_paste) {
                    try gui.widgetPaste(chunk.bytes[0..chunk.len]);
                } else {
                    _ = try client.controllers.paste_routing.content(app, chunk.bytes[0..chunk.len]);
                }
            },
            .paste_finish => {
                if (input.widget_paste) {
                    try gui.endWidgetPaste();
                } else {
                    _ = try client.controllers.paste_routing.finish(app);
                }

                input.widget_paste = false;
            },
            .release_recovery => {
                if (!input.recovery.pointer_finished) {
                    try input.pointer.cancel(app);
                    handler.cancelPointer();
                    _ = try gui.widgetInput(.{ .focus = false });
                    _ = try gui.widgetInput(.{ .focus = gui.focused });
                    input.scroll_remainder = 0;
                    input.recovery.pointer_finished = true;
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                if (input.recovery.next()) |key| {
                    try input.dispatchKey(&handler, key);
                    input.recovery.finish(key);
                    if (input.recovery.len != 0) {
                        continue;
                    }
                }

                input.recovery.queued = false;
                input.recovery.pointer_finished = false;
            },
            .pointer => |event| {
                if (event.event.interruptsKeys()) {
                    input.cancelBinding();
                }

                if (event.event.retained() or (event.geometry_revision == input.pointer.revision and event.gesture_revision == input.pointer.gesture_revision)) {
                    if (try gui.widgetInput(.{ .pointer = event.event })) {
                        input.head = (input.head + 1) % capacity;
                        input.len -= 1;
                        continue;
                    }
                }

                try input.pointer.apply(app, event);
            },
            .scroll => |*sample| {
                if (!try input.dispatchScroll(app, sample)) {
                    continue;
                }
            },
            .owned_small => |index| {
                _ = try gui.widgetInput(input.small_events.view(index));
                input.small_events.release(index);
            },
            .composition_cancel => |value| _ = try gui.widgetInput(.{ .composition = value }),
            .owned_large => |index| {
                if (!try input.dispatchClipboard(gui, input.large_events.view(index).clipboard)) {
                    continue;
                }

                input.large_events.release(index);
            },
        }

        app.telemetry.metrics.key_lease_overflows +%= input.router.leaseOverflowCount() -% overflows;
        input.head = (input.head + 1) % capacity;
        input.len -= 1;
    }

    try input.finish(app, pending);
}

fn dispatchKey(input: *Input, handler: *InputHandler, key: KeyInput) !void {
    if (try GuiClient.of(handler.app).widgetInput(.{ .key = key })) {
        return;
    }

    if (key.code == .char and key.code.char.len == 1 and std.ascii.toLower(key.code.char.bytes[0]) == 'v' and (key.mods.super or (key.mods.ctrl and key.mods.shift))) {
        if (key.phase == .press and key.target_id == 0) {
            input.terminal_clipboard.read(GuiClient.of(handler.app)) catch |err| switch (err) {
                error.HostRequestsFull => {},
                else => return err,
            };
        }

        return;
    }

    if (key.mods.super or key.target_id != 0) {
        return;
    }

    input.stopped = try input.router.routeEvent(.{ .key = key.terminalKey(), .raw = "", .now_ns = client.monotonic(handler.app.io) }, handler) == .stop;
}

fn dispatchClipboard(input: *Input, gui: *GuiClient, result: @import("input/ClipboardResult.zig")) !bool {
    if (input.clipboard_offset == null) {
        const kind = gui.host.complete(result) orelse return true;
        if (kind == .write) {
            if (result.target_id != 0) {
                var completion = result;
                completion.operation = .write;
                _ = try gui.widgetInput(.{ .clipboard = completion });
            }

            return true;
        }

        if (result.target_id != 0) {
            _ = try gui.widgetInput(.{ .clipboard = result });
            return true;
        }

        if (!input.terminal_clipboard.take(gui, result)) {
            return true;
        }

        var handler: InputHandler = .{ .app = &gui.app };
        try input.router.interrupt(&handler);
        _ = try client.controllers.pane_pastes.start(&gui.app);
        input.clipboard_offset = 0;
        return false;
    }

    const offset = input.clipboard_offset.?;
    if (offset < result.text.len) {
        const count = pasteChunkSize(result.text[offset..]);
        _ = try client.controllers.pane_pastes.content(&gui.app, result.text[offset..][0..count]);
        input.clipboard_offset = offset + count;
        return false;
    }

    _ = try client.controllers.pane_pastes.finish(&gui.app);
    input.clipboard_offset = null;
    return true;
}

fn dispatchScroll(input: *Input, app: *client.AttachedClient, sample: *@import("input/ScrollSample.zig")) !bool {
    if (sample.geometry_revision != input.pointer.revision or sample.gesture_revision != input.pointer.gesture_revision) {
        input.scroll_remainder = 0;
        return true;
    }

    const event = sample.event;
    if (!sample.started) {
        if (try GuiClient.of(app).widgetInput(.{ .scroll = event })) {
            input.scroll_remainder = 0;
            return true;
        }

        if (event.phase == .begin or event.phase == .cancel) {
            input.scroll_remainder = 0;
        }

        if (event.phase == .cancel) {
            return true;
        }

        const unit: f64 = if (event.precise) @floatFromInt(@max(1, input.pointer.geometry.size.cell_height_px)) else 1;
        input.scroll_remainder += std.math.clamp(event.delta_y / unit, -32, 32);
        sample.lines = @intFromFloat(std.math.clamp(@trunc(input.scroll_remainder), -32, 32));
        input.scroll_remainder -= @floatFromInt(sample.lines);
        sample.started = true;
    }

    if (sample.lines == 0) {
        return true;
    }

    const pointer: @import("input/PointerEvent.zig") = .{ .kind = if (sample.lines < 0) .scroll_up else .scroll_down, .mods = event.mods, .x = event.x, .y = event.y };
    input.cancelBinding();
    try input.pointer.apply(app, input.pointer.sample(pointer));
    sample.lines += if (sample.lines < 0) @as(i8, 1) else -1;
    return sample.lines == 0;
}

fn finish(input: *Input, app: *client.AttachedClient, pending: bool) !void {
    if (input.router.bindingDeadline() == null and !input.router.prefixPending()) {
        input.binding_target = null;
    }

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

fn pushKey(input: *Input, key: KeyInput, source: enum { key, text }) !void {
    input.reserve(1) catch |err| {
        if (key.phase != .release or key.physical == null) {
            return err;
        }

        input.recovery.retain(key);
        input.scheduleRecovery();
        return;
    };

    input.push(switch (source) {
        .key => .{ .key = key },
        .text => .{ .text = .{ .bytes = key.code.char.bytes, .len = key.code.char.len, .phase = key.phase, .physical = key.physical } },
    });
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
        try std.testing.expectEqualDeep(try client.parseKey(name), key.terminalKey());
    }

    try std.testing.expectEqual(@as(u32, 50), input.items[0].key.physical.?.value);
}

test "native input rejects invalid pointer and key payloads atomically" {
    var input: Input = .{};
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 1, .x = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 8 }));
    try std.testing.expectError(error.InvalidNativePointer, input.accept(.{ .kind = 6, .code = 1, .button = 3 }));
    try std.testing.expectError(error.InvalidNativeInput, input.accept(.{ .kind = 4, .code = 'x', .mods = 16 }));
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

test "native committed text stays owned and distinct from keys until dispatch" {
    var input: Input = .{};
    var bytes = [_]u8{ 'a', 'b' };
    try input.accept(.{ .kind = 1, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'x');
    try input.accept(.{ .kind = 4, .code = 'c', .physical = 3 });
    try std.testing.expectEqual(@as(usize, 3), input.len);
    try std.testing.expectEqualStrings("a", input.items[0].text.text().bytes);
    try std.testing.expectEqualStrings("b", input.items[1].text.text().bytes);
    try std.testing.expectEqual(@as(u8, 'c'), input.items[2].key.code.char.bytes[0]);
    try std.testing.expect(input.items[0].text.physical == null);
}

test "targeted commits enter atomically with replacement metadata and owned UTF8" {
    var input: Input = .{};
    var bytes = [_]u8{ 'a', 'b' };
    try input.accept(.{ .kind = 1, .target_id = 3, .generation = 9, .text = &bytes, .len = bytes.len, .replacement_start = 1, .replacement_end = 5 });
    @memset(&bytes, 'x');
    try std.testing.expectEqual(@as(usize, 1), input.len);
    const event = input.small_events.view(input.items[0].owned_small).text;
    try std.testing.expectEqualStrings("ab", event.bytes);
    try std.testing.expectEqual(@as(u32, 5), event.replacement_end);
    try std.testing.expectEqual(@as(u64, 9), event.generation);
    input.len = capacity - 1;
    try std.testing.expectError(error.NativeInputFull, input.accept(.{ .kind = 1, .target_id = 3, .text = &bytes, .len = bytes.len }));
    try std.testing.expectEqual(capacity - 1, input.len);
    try input.accept(.{ .kind = 1, .target_id = 3, .generation = 9, .phase = 3, .physical = 1, .text = "a", .len = 1 });
    try std.testing.expectEqual(capacity, input.len);
    try std.testing.expect(input.recovery.queued);
    try std.testing.expectEqual(@as(u64, 3), input.recovery.next().?.target_id);
}

test "composition cancellation remains admissible with exhausted payload slots or input ring" {
    var input: Input = .{};
    for (0..8) |_| {
        try input.accept(.{ .kind = 7, .code = 1, .target_id = 12, .generation = 3, .text = "a", .len = 1 });
    }

    try input.accept(.{ .kind = 7, .code = 2, .target_id = 12, .generation = 3 });
    try std.testing.expect(input.items[8] == .composition_cancel);
    try std.testing.expectEqual(@as(u64, 12), input.items[8].composition_cancel.target_id);
    input.len = capacity - 1;
    try input.accept(.{ .kind = 7, .code = 2, .target_id = 12, .generation = 3 });
    try std.testing.expect(input.recovery.queued);
    try std.testing.expect(input.items[capacity - 1] == .release_recovery);
    try std.testing.expectEqual(capacity, input.len);
}
