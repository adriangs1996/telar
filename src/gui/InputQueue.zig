//! Ordered, bounded input storage. Owns payload lifetimes and release recovery.
const native = @import("native/native.zig");
const input_item = @import("input_item.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const event_types = @import("input/event.zig");
const decode_input = @import("native/decode_input.zig");
const ReleaseRecovery = @import("input/ReleaseRecovery.zig");
const PasteChunk = @import("PasteChunk.zig");
const KeyInput = @import("input/KeyInput.zig");
const GenericEventPool = @import("input/GenericEventPool.zig").Type;
const InputQueue = @This();
const PointerStamp = @import("input/PointerStamp.zig");

pub const max_paste_bytes = event_types.max_text_bytes;
const capacity = 1024;
items: [capacity]input_item.Item = undefined,
head: usize = 0,
len: usize = 0,
recovery: ReleaseRecovery = .{},
small_events: GenericEventPool(4096, 8) = .{},
large_events: GenericEventPool(max_paste_bytes, 2) = .{},

/// Copies borrowed payloads atomically into bounded storage. Recovery admission
/// requires the owner to invalidate gestures before accepting another event.
/// Example: `const result = try queue.accept(event, stamp);`
pub fn accept(self: *InputQueue, event: event_types.Event, stamp: PointerStamp) !input_item.Admission {
    switch (event) {
        .pointer => |pointer| {
            self.reserve(1) catch |err| {
                if (pointer.kind != .release and pointer.kind != .leave) {
                    return err;
                }

                self.requestRecovery();
                return .recovery;
            };
            self.push(.{ .pointer = .{ .event = pointer, .geometry_revision = stamp.geometry_revision, .gesture_revision = stamp.gesture_revision } });
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
                return self.pushKey(key, .key);
            }

            if (text.target_id != 0) {
                try self.reserve(1);
                self.push(.{ .owned_small = try self.small_events.admit(event) });
                return .accepted;
            }

            const view = try std.unicode.Utf8View.init(text.bytes);
            var iterator = view.iterator();
            var count: usize = 0;
            while (iterator.nextCodepoint() != null) {
                count += 1;
            }

            self.reserve(count) catch |err| {
                if (count != 1 or text.phase != .release or text.physical == null) {
                    return err;
                }
            };
            var admission: input_item.Admission = .accepted;
            iterator = view.iterator();
            while (iterator.nextCodepointSlice()) |bytes| {
                var key: KeyInput = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(bytes.len) } }, .phase = text.phase };
                @memcpy(key.code.char.bytes[0..bytes.len], bytes);
                if (count == 1) {
                    key.physical = text.physical;
                }

                admission = try self.pushKey(key, .text);
            }

            return admission;
        },
        .paste => |text| {
            if (text.len > max_paste_bytes) {
                return error.InputTooLarge;
            }

            if (!std.unicode.utf8ValidateSlice(text)) {
                return error.InvalidUtf8;
            }

            if (text.len == 0) {
                return .accepted;
            }

            var offset: usize = 0;
            var chunks: usize = 0;
            while (offset < text.len) {
                offset += PasteChunk.nextSize(text[offset..]);
                chunks += 1;
            }

            try self.reserve(chunks + 2);
            self.push(.paste_start);
            offset = 0;
            while (offset < text.len) {
                const count = PasteChunk.nextSize(text[offset..]);
                var chunk: PasteChunk = .{ .len = @intCast(count) };
                @memcpy(chunk.bytes[0..count], text[offset..][0..count]);
                self.push(.{ .paste_text = chunk });
                offset += count;
            }

            self.push(.paste_finish);
        },
        .key => |key| return self.pushKey(key, .key),
        .focus => return error.FocusRequiresHostDispatch,
        .scroll => |scroll| {
            try self.reserve(1);
            self.push(.{ .scroll = .{ .event = scroll, .geometry_revision = stamp.geometry_revision, .gesture_revision = stamp.gesture_revision } });
        },
        .clipboard => {
            try self.reserve(1);
            self.push(.{ .owned_large = try self.large_events.admit(event) });
        },
        .composition => |value| {
            if (value.cancel) {
                self.reserve(1) catch {
                    self.requestRecovery();
                    return .recovery;
                };

                self.push(.{ .composition_cancel = .{ .target_id = value.target_id, .generation = value.generation, .cancel = true } });
                return .accepted;
            }

            try self.reserve(1);
            self.push(.{ .owned_small = try self.small_events.admit(event) });
        },
        .accessibility, .delete_surrounding => {
            try self.reserve(1);
            self.push(.{ .owned_small = try self.small_events.admit(event) });
        },
    }

    return .accepted;
}

/// Borrow the oldest event until it is fully processed. Partial scroll/paste
/// delivery retains the same slot. Example: `const event = input.front() orelse return;`
pub fn front(self: *InputQueue) ?*input_item.Item {
    if (self.len == 0) {
        return null;
    }

    return &self.items[self.head];
}

/// Release owned payload storage only after successful delivery, then advance
/// the ring. Example: `try dispatch(event); input.consume();`
pub fn consume(self: *InputQueue) void {
    std.debug.assert(self.len != 0);
    switch (self.items[self.head]) {
        .owned_small => |index| self.small_events.release(index),
        .owned_large => |index| self.large_events.release(index),
        .release_recovery => {
            std.debug.assert(self.recovery.len == 0);
            self.recovery.queued = false;
        },
        else => {},
    }

    self.head = (self.head + 1) % capacity;
    self.len -= 1;
}

fn reserve(self: *const InputQueue, count: usize) !void {
    if (self.recovery.queued or count > (capacity - 1) -| self.len) {
        return error.NativeInputFull;
    }
}

fn pushKey(self: *InputQueue, key: KeyInput, source: enum { key, text }) !input_item.Admission {
    self.reserve(1) catch |err| {
        if (key.phase != .release or key.physical == null) {
            return err;
        }

        self.recovery.retain(key);
        self.requestRecovery();
        return .recovery;
    };

    self.push(switch (source) {
        .key => .{ .key = key },
        .text => .{ .text = .{ .bytes = key.code.char.bytes, .len = key.code.char.len, .phase = key.phase, .physical = key.physical } },
    });

    return .accepted;
}

/// Reserves ordered recovery even when ordinary event admission is saturated.
/// Example: `input.requestRecovery();`
pub fn requestRecovery(self: *InputQueue) void {
    if (self.recovery.queued) {
        return;
    }

    std.debug.assert(self.len < capacity);
    self.push(.release_recovery);
    self.recovery.queued = true;
}

fn push(self: *InputQueue, item: input_item.Item) void {
    self.items[(self.head + self.len) % capacity] = item;
    self.len += 1;
}

test "native paste admission is atomic and owns the borrowed bytes" {
    var input: InputQueue = .{};
    var bytes = [_]u8{'x'} ** 257;
    try acceptNative(&input, .{ .kind = 2, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'y');
    try std.testing.expectEqual(@as(usize, 4), input.len);
    try std.testing.expectEqual(@as(u8, 'x'), input.items[1].paste_text.bytes[0]);
    input.len = capacity - 1;
    try std.testing.expectError(error.NativeInputFull, acceptNative(&input, .{ .kind = 2, .text = &bytes, .len = bytes.len }));
    try std.testing.expectEqual(capacity - 1, input.len);
}

test "native key normalization preserves configured Ctrl-Space Alt uppercase and back-tab" {
    var input: InputQueue = .{};
    try acceptNative(&input, .{ .kind = 4, .code = ' ', .mods = 4, .physical = 50 });
    try acceptNative(&input, .{ .kind = 4, .code = 'B', .mods = 4 });
    try acceptNative(&input, .{ .kind = 4, .code = 'N', .mods = 3 });
    try acceptNative(&input, .{ .kind = 3, .code = 2, .mods = 1 });
    const expected = [_][]const u8{ "ctrl+space", "ctrl+b", "alt+N", "shift+tab" };
    for (expected, 0..) |name, index| {
        var key = input.items[index].key;
        key.physical = null;
        try std.testing.expectEqualDeep(try data.chord.parseKey(name), key.terminalKey());
    }

    try std.testing.expectEqual(@as(u32, 50), input.items[0].key.physical.?.value);
}

test "native input rejects invalid pointer and key payloads atomically" {
    var input: InputQueue = .{};
    try std.testing.expectError(error.InvalidNativePointer, acceptNative(&input, .{ .kind = 6, .code = 1, .x = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidNativePointer, acceptNative(&input, .{ .kind = 6, .code = 8 }));
    try std.testing.expectError(error.InvalidNativePointer, acceptNative(&input, .{ .kind = 6, .code = 1, .button = 3 }));
    try std.testing.expectError(error.InvalidNativeInput, acceptNative(&input, .{ .kind = 4, .code = 'x', .mods = 16 }));
    try std.testing.expectError(error.InvalidNativeKey, acceptNative(&input, .{ .kind = 3, .code = 99 }));
    try std.testing.expectError(error.InvalidUtf8, acceptNative(&input, .{ .kind = 1, .text = "\xff", .len = 1 }));
    try std.testing.expectEqual(@as(usize, 0), input.len);
}

test "native paste chunks preserve UTF-8 scalar boundaries for prompt editing" {
    var input: InputQueue = .{};
    const bytes = "a" ** 255 ++ "🌍" ++ "b" ** 255;
    try acceptNative(&input, .{ .kind = 2, .text = bytes.ptr, .len = bytes.len });
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
    var input: InputQueue = .{};
    var bytes = [_]u8{ 'a', 'b' };
    try acceptNative(&input, .{ .kind = 1, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'x');
    try acceptNative(&input, .{ .kind = 4, .code = 'c', .physical = 3 });
    try std.testing.expectEqual(@as(usize, 3), input.len);
    try std.testing.expectEqualStrings("a", input.items[0].text.text().bytes);
    try std.testing.expectEqualStrings("b", input.items[1].text.text().bytes);
    try std.testing.expectEqual(@as(u8, 'c'), input.items[2].key.code.char.bytes[0]);
    try std.testing.expect(input.items[0].text.physical == null);
}

test "targeted commits enter atomically with replacement metadata and owned UTF8" {
    var input: InputQueue = .{};
    var bytes = [_]u8{ 'a', 'b' };
    try acceptNative(&input, .{ .kind = 1, .target_id = 3, .generation = 9, .text = &bytes, .len = bytes.len, .replacement_start = 1, .replacement_end = 5 });
    @memset(&bytes, 'x');
    try std.testing.expectEqual(@as(usize, 1), input.len);
    const event = input.small_events.view(input.items[0].owned_small).text;
    try std.testing.expectEqualStrings("ab", event.bytes);
    try std.testing.expectEqual(@as(u32, 5), event.replacement_end);
    try std.testing.expectEqual(@as(u64, 9), event.generation);
    input.len = capacity - 1;
    try std.testing.expectError(error.NativeInputFull, acceptNative(&input, .{ .kind = 1, .target_id = 3, .text = &bytes, .len = bytes.len }));
    try std.testing.expectEqual(capacity - 1, input.len);
    try acceptNative(&input, .{ .kind = 1, .target_id = 3, .generation = 9, .phase = 3, .physical = 1, .text = "a", .len = 1 });
    try std.testing.expectEqual(capacity, input.len);
    try std.testing.expect(input.recovery.queued);
    try std.testing.expectEqual(@as(u64, 3), input.recovery.next().?.target_id);
}

test "composition cancellation remains admissible with exhausted payload slots or input ring" {
    var input: InputQueue = .{};
    for (0..8) |_| {
        try acceptNative(&input, .{ .kind = 7, .code = 1, .target_id = 12, .generation = 3, .text = "a", .len = 1 });
    }

    try acceptNative(&input, .{ .kind = 7, .code = 2, .target_id = 12, .generation = 3 });
    try std.testing.expect(input.items[8] == .composition_cancel);
    try std.testing.expectEqual(@as(u64, 12), input.items[8].composition_cancel.target_id);
    input.len = capacity - 1;
    try acceptNative(&input, .{ .kind = 7, .code = 2, .target_id = 12, .generation = 3 });
    try std.testing.expect(input.recovery.queued);
    try std.testing.expect(input.items[capacity - 1] == .release_recovery);
    try std.testing.expectEqual(capacity, input.len);
}

test "queued payloads survive borrowing and their slots can be reused across ring wrap" {
    var input: InputQueue = .{};
    for (0..capacity + 1) |_| {
        var bytes = [_]u8{ 'a', 'b' };
        _ = try input.accept(.{ .text = .{ .bytes = &bytes, .target_id = 1 } }, .{});
        _ = try input.accept(.{ .clipboard = .{ .request_id = 1, .target_id = 0, .generation = 0, .status = .success, .text = &bytes } }, .{});
        @memset(&bytes, 'x');
        const text = input.front().?;
        try std.testing.expectEqualStrings("ab", input.small_events.view(text.owned_small).text.bytes);
        try std.testing.expectEqual(text, input.front().?);
        input.consume();
        const clipboard = input.front().?;
        try std.testing.expectEqualStrings("ab", input.large_events.view(clipboard.owned_large).clipboard.text);
        input.consume();
        try std.testing.expect(input.front() == null);
    }
}

fn acceptNative(queue: *InputQueue, event: native.InputEvent) !void {
    _ = try queue.accept(try decode_input.decode(event), .{});
}

test "recovery keeps admission closed until retained releases and the marker are consumed" {
    var queue: InputQueue = .{};
    _ = try queue.accept(.{ .text = .{ .bytes = "a" } }, .{});
    queue.requestRecovery();
    const release: KeyInput = .{ .code = .{ .char = .init("a") }, .phase = .release, .physical = .{ .value = 1 } };
    try std.testing.expectEqual(input_item.Admission.recovery, try queue.accept(.{ .key = release }, .{}));
    queue.consume();
    try std.testing.expect(queue.front().?.* == .release_recovery);
    try std.testing.expectError(error.NativeInputFull, queue.accept(.{ .text = .{ .bytes = "b" } }, .{}));
    const retained = queue.recovery.next().?;
    try std.testing.expectEqualDeep(release, retained);
    queue.recovery.finish(retained);
    try std.testing.expectError(error.NativeInputFull, queue.accept(.{ .text = .{ .bytes = "b" } }, .{}));
    queue.consume();
    try std.testing.expect(!queue.recovery.queued);
    try std.testing.expectEqual(input_item.Admission.accepted, try queue.accept(.{ .text = .{ .bytes = "b" } }, .{}));
    try std.testing.expectEqualStrings("b", queue.front().?.text.text().bytes);
}
