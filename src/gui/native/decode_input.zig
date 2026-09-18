//! One checked translation of the native ABI into synchronous semantic input.
const std = @import("std");
const client = @import("telar-client");
const NativeEvent = @import("InputEvent.zig").InputEvent;
const events = @import("../input/event.zig");
const PointerEvent = @import("../input/PointerEvent.zig");
const KeyInput = @import("../input/KeyInput.zig");
const ReleaseRecovery = @import("../input/ReleaseRecovery.zig");

/// Text remains borrowed until its receiver copies it. Native tags, phases,
/// lengths and coordinates are checked before any input state changes.
/// Example: `const event = try decode(native_event);`
pub fn decode(native: NativeEvent) !events.Event {
    if (native.len > events.max_text_bytes) {
        return error.InputTooLarge;
    }

    if ((native.len != 0 and native.text == null) or native.mods > 15 or (native.kind <= 4 and (native.phase < 1 or native.phase > 3)) or native.physical > ReleaseRecovery.capacity) {
        return error.InvalidNativeInput;
    }

    if (native.kind == 6) {
        if (native.code < 1 or native.code > 7 or native.button > 2 or native.len != 0 or !std.math.isFinite(native.x) or !std.math.isFinite(native.y)) {
            return error.InvalidNativePointer;
        }

        const kinds = [_]PointerEvent.Kind{ .press, .release, .drag, .scroll_up, .scroll_down, .move, .leave };
        return .{ .pointer = .{ .kind = kinds[native.code - 1], .button = @enumFromInt(native.button), .mods = @intCast(native.mods), .x = native.x, .y = native.y } };
    }

    const text = if (native.text) |ptr| ptr[0..native.len] else "";
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    const phase: client.Key.Phase = if (native.kind <= 4) @enumFromInt(native.phase) else .press;
    const physical: ?client.Key.Physical = if (native.physical == 0) null else .{ .value = native.physical };
    switch (native.kind) {
        1 => {
            if (native.target_id != 0) {
                try replacementRange(native);
            }

            return .{ .text = .{ .bytes = text, .phase = phase, .physical = physical, .target_id = native.target_id, .generation = native.generation, .replacement_start = if (native.target_id != 0) native.replacement_start else std.math.maxInt(u32), .replacement_end = if (native.target_id != 0) native.replacement_end else std.math.maxInt(u32) } };
        },
        2 => return .{ .paste = text },
        3 => {
            const codes = [_]client.Key.Code{ .enter, .tab, .backspace, .escape, .up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down };
            var key: KeyInput = .{
                .code = if (native.code >= 1 and native.code <= codes.len) codes[native.code - 1] else return error.InvalidNativeKey,
                .mods = @bitCast(@as(u4, @intCast(native.mods))),
                .phase = phase,
                .physical = physical,
                .target_id = native.target_id,
                .generation = native.generation,
            };
            if (key.code == .tab and key.mods.shift and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                key.code = .back_tab;
                key.mods.shift = false;
            }

            return .{ .key = key };
        },
        4 => {
            var key: KeyInput = .{
                .code = .{ .char = .{ .bytes = @splat(0), .len = 0 } },
                .mods = @bitCast(@as(u4, @intCast(native.mods))),
                .phase = phase,
                .physical = physical,
                .target_id = native.target_id,
                .generation = native.generation,
            };
            key.code.char.len = try std.unicode.utf8Encode(std.math.cast(u21, native.code) orelse return error.InvalidNativeKey, &key.code.char.bytes);
            if ((key.mods.ctrl or key.mods.super) and key.code.char.len == 1) {
                key.code.char.bytes[0] = std.ascii.toLower(key.code.char.bytes[0]);
            }

            if (!key.mods.ctrl and !key.mods.super) {
                key.mods.shift = false;
            }

            return .{ .key = key };
        },
        5 => {
            if (native.code > 1 or native.len != 0) {
                return error.InvalidNativeFocus;
            }

            return .{ .focus = native.code == 1 };
        },
        7 => {
            if (native.target_id == 0 or native.code < 1 or native.code > 2 or text.len > events.max_composition_bytes) {
                return error.InvalidNativeComposition;
            }

            try selectionRange(text, native.selection_start, native.selection_end);
            try replacementRange(native);
            return .{ .composition = .{ .target_id = native.target_id, .generation = native.generation, .text = text, .selection_start = native.selection_start, .selection_end = native.selection_end, .replacement_start = native.replacement_start, .replacement_end = native.replacement_end, .cancel = native.code == 2 } };
        },
        8 => {
            if (text.len != 0 or native.precise > 1 or native.scroll_phase > 4 or native.momentum_phase > 4 or !std.math.isFinite(native.x) or !std.math.isFinite(native.y) or !std.math.isFinite(native.delta_x) or !std.math.isFinite(native.delta_y)) {
                return error.InvalidNativeScroll;
            }

            return .{ .scroll = .{ .x = native.x, .y = native.y, .delta_x = native.delta_x, .delta_y = native.delta_y, .mods = @intCast(native.mods), .precise = native.precise == 1, .phase = @enumFromInt(native.scroll_phase), .momentum = @enumFromInt(native.momentum_phase) } };
        },
        9 => {
            if (native.request_id == 0 or native.code > 4 or (native.code != 0 and native.code != 4 and text.len != 0)) {
                return error.InvalidNativeClipboard;
            }

            return .{ .clipboard = .{ .request_id = native.request_id, .target_id = native.target_id, .generation = native.generation, .status = if (native.code == 4) .success else @enumFromInt(native.code), .image = native.code == 4, .text = text } };
        },
        10 => {
            if (native.target_id == 0 or text.len > events.max_composition_bytes) {
                return error.InvalidNativeAccessibility;
            }

            const action = std.enums.fromInt(@import("../input/AccessibilityAction.zig").Action, native.code) orelse return error.InvalidNativeAccessibility;
            if (action == .replace_range) {
                try replacementRange(native);
                if (native.revision == 0 or native.replacement_start == std.math.maxInt(u32)) {
                    return error.InvalidNativeAccessibility;
                }
            }

            return .{ .accessibility = .{ .target_id = native.target_id, .generation = native.generation, .revision = native.revision, .action = action, .text = text, .selection_start = native.selection_start, .selection_end = native.selection_end, .replacement_start = native.replacement_start, .replacement_end = native.replacement_end } };
        },
        11 => {
            if (native.target_id == 0 or text.len != 0 or native.replacement_start > events.max_composition_bytes or native.replacement_end > events.max_composition_bytes) {
                return error.InvalidNativeComposition;
            }

            return .{ .delete_surrounding = .{ .target_id = native.target_id, .generation = native.generation, .before = native.replacement_start, .after = native.replacement_end } };
        },
        else => return error.InvalidNativeInput,
    }
}

fn replacementRange(native: NativeEvent) !void {
    const none = std.math.maxInt(u32);
    if (native.replacement_start == none and native.replacement_end == none) {
        return;
    }

    if (native.replacement_start > native.replacement_end or native.replacement_end > events.max_composition_bytes) {
        return error.InvalidNativeComposition;
    }
}

fn selectionRange(text: []const u8, start: u32, end: u32) !void {
    if (start > text.len or end > text.len) {
        return error.InvalidNativeComposition;
    }

    if ((start < text.len and text[start] & 0xc0 == 0x80) or (end < text.len and text[end] & 0xc0 == 0x80)) {
        return error.InvalidNativeComposition;
    }
}

test "semantic native decoder preserves held keys committed text and focus" {
    for ([_]client.Key.Phase{ .press, .repeat, .release }) |phase| {
        const key = (try decode(.{ .kind = 3, .code = 5, .physical = 127, .phase = @intFromEnum(phase) })).key;
        try std.testing.expectEqual(phase, key.phase);
        try std.testing.expectEqual(@as(u32, 127), key.physical.?.value);
        try std.testing.expect(key.code == .up);
    }

    const text = (try decode(.{ .kind = 1, .text = "日本語", .len = "日本語".len })).text;
    try std.testing.expectEqualStrings("日本語", text.bytes);
    try std.testing.expect(text.physical == null);
    try std.testing.expect(!(try decode(.{ .kind = 5, .code = 0 })).focus);
    try std.testing.expect((try decode(.{ .kind = 5, .code = 1 })).focus);
}

test "semantic native decoder rejects malformed payloads before dispatch" {
    try std.testing.expectError(error.InvalidNativeInput, decode(.{ .kind = 1, .len = 1 }));
    try std.testing.expectError(error.InvalidNativeInput, decode(.{ .kind = 3, .phase = 0 }));
    try std.testing.expectError(error.InvalidNativeInput, decode(.{ .kind = 3, .physical = 257 }));
    try std.testing.expectError(error.InvalidNativePointer, decode(.{ .kind = 6, .code = 1, .button = 3 }));
    try std.testing.expectError(error.InvalidNativePointer, decode(.{ .kind = 6, .code = 1, .y = std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidNativeFocus, decode(.{ .kind = 5, .code = 2 }));
    try std.testing.expectError(error.InvalidUtf8, decode(.{ .kind = 1, .text = "\xff", .len = 1 }));
    try std.testing.expectError(error.InputTooLarge, decode(.{ .kind = 2, .len = events.max_text_bytes + 1 }));
}

test "IME ranges preserve UTF8 boundaries and distinguish absent replacement" {
    const event = try decode(.{ .kind = 7, .code = 1, .phase = 0, .target_id = 42, .generation = 8, .text = "a🌍b", .len = 6, .selection_start = 1, .selection_end = 5 });
    try std.testing.expectEqual(@as(u32, 5), event.composition.selection_end);
    try std.testing.expectEqual(std.math.maxInt(u32), event.composition.replacement_start);
    try std.testing.expectError(error.InvalidNativeComposition, decode(.{ .kind = 7, .code = 1, .target_id = 42, .text = "🌍", .len = 4, .selection_start = 1 }));
    try std.testing.expectError(error.InvalidNativeComposition, decode(.{ .kind = 1, .target_id = 42, .replacement_start = 2, .replacement_end = 1 }));
    const committed = (try decode(.{ .kind = 1, .target_id = 42, .generation = 8, .text = "日本", .len = 6, .replacement_start = 1, .replacement_end = 5 })).text;
    try std.testing.expectEqualStrings("日本", committed.bytes);
    try std.testing.expectEqual(@as(u32, 1), committed.replacement_start);
    const legacy = (try decode(.{ .kind = 1, .replacement_start = 0, .replacement_end = 0 })).text;
    try std.testing.expectEqual(std.math.maxInt(u32), legacy.replacement_end);
}

test "host result identities and precise scroll phases survive translation" {
    const scroll = (try decode(.{ .kind = 8, .phase = 0, .delta_x = 0.125, .delta_y = -0.25, .precise = 1, .scroll_phase = 2, .momentum_phase = 3 })).scroll;
    try std.testing.expectEqual(@as(f64, 0.125), scroll.delta_x);
    try std.testing.expectEqual(@as(f64, -0.25), scroll.delta_y);
    try std.testing.expect(scroll.phase == .update and scroll.momentum == .end and scroll.precise);
    try std.testing.expectError(error.InvalidNativeScroll, decode(.{ .kind = 8, .delta_y = std.math.nan(f64) }));
    const result = (try decode(.{ .kind = 9, .phase = 0, .request_id = 99, .target_id = 42, .generation = 8, .code = 3 })).clipboard;
    try std.testing.expectEqual(@as(u64, 99), result.request_id);
    try std.testing.expect(result.status == .cancelled);
    try std.testing.expectError(error.InvalidNativeClipboard, decode(.{ .kind = 9, .request_id = 0 }));
    try std.testing.expectError(error.InvalidNativeAccessibility, decode(.{ .kind = 10, .target_id = 42, .code = 3 }));
}

test "GUI Command shortcuts remain distinct from terminal control chords" {
    const key = (try decode(.{ .kind = 4, .code = 'V', .mods = 9, .physical = 10, .target_id = 42, .generation = 8 })).key;
    try std.testing.expect(key.mods.super and key.mods.shift and !key.mods.ctrl);
    try std.testing.expectEqual(@as(u8, 'v'), key.code.char.bytes[0]);
    try std.testing.expectEqual(@as(u64, 42), key.target_id);
    try std.testing.expectEqual(@as(u32, 10), key.physical.?.value);
}
