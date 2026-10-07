//! One checked translation of the native ABI into synchronous semantic input.
const input = @import("Input.zig");
const Input = input.Input;
const keyinput = @import("keyinput");
const AccessibilityAction = @FieldType(Input, "accessibility");
const std = @import("std");
const native_input = @import("NativeInput.zig");
const NativeEvent = native_input.NativeInput;
const PointerEvent = @FieldType(Input, "pointer");
const KeyInput = @FieldType(Input, "key");
const physical_key_capacity = 256;

/// Text remains borrowed until its receiver copies it. Native tags, phases,
/// lengths and coordinates are checked before any input state changes.
/// Example: `const event = try decode(native_event);`
pub fn decode(native: NativeEvent) !Input {
    if (native.len > Input.max_text_bytes) {
        return error.InputTooLarge;
    }

    if ((native.len != 0 and native.text == null) or native.mods > 15 or (native.kind <= 4 and (native.phase < 1 or native.phase > 3)) or native.physical > physical_key_capacity) {
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

    const phase: keyinput.Key.Phase = if (native.kind <= 4) @enumFromInt(native.phase) else .press;
    const physical: ?keyinput.Key.Physical = if (native.physical == 0) null else .{
        .value = native.physical,
    };
    switch (native.kind) {
        1 => {
            if (native.target_id != 0) {
                try replacementRange(native);
            }

            return .{ .text = .{ .bytes = text, .phase = phase, .physical = physical, .target_id = native.target_id, .generation = native.generation, .replacement_start = if (native.target_id != 0) native.replacement_start else std.math.maxInt(u32), .replacement_end = if (native.target_id != 0) native.replacement_end else std.math.maxInt(u32) } };
        },
        2 => return .{ .paste = text },
        3 => {
            const codes = [_]keyinput.Key.Code{
                .enter,
                .tab,
                .backspace,
                .escape,
                .up,
                .down,
                .left,
                .right,
                .home,
                .end,
                .delete,
                .page_up,
                .page_down,
            };
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
            if (native.target_id == 0 or native.code < 1 or native.code > 2 or text.len > Input.max_composition_bytes) {
                return error.InvalidNativeComposition;
            }

            try selectionRange(text, native.selection_start, native.selection_end);
            try replacementRange(native);
            return .{ .composition = .{ .target_id = native.target_id, .generation = native.generation, .text = text, .selection_start = native.selection_start, .selection_end = native.selection_end, .replacement_start = native.replacement_start, .replacement_end = native.replacement_end, .cancel = native.code == 2 } };
        },
        8 => {
            if (text.len != 0 or native.precise > 1 or native.scroll_phase > 4 or native.momentum_phase > 4 or native.scroll_kinetic > 1 or (native.scroll_kinetic == 1 and native.precise == 0) or !std.math.isFinite(native.x) or !std.math.isFinite(native.y) or !std.math.isFinite(native.delta_x) or !std.math.isFinite(native.delta_y)) {
                return error.InvalidNativeScroll;
            }

            return .{ .scroll = .{ .x = native.x, .y = native.y, .delta_x = native.delta_x, .delta_y = native.delta_y, .mods = @intCast(native.mods), .precise = native.precise == 1, .phase = @enumFromInt(native.scroll_phase) } };
        },
        9 => {
            if (native.request_id == 0 or native.code > 3 or (native.code != 0 and text.len != 0)) {
                return error.InvalidNativeClipboard;
            }

            return .{ .clipboard = .{ .request_id = native.request_id, .target_id = native.target_id, .generation = native.generation, .status = @enumFromInt(native.code), .text = text } };
        },
        10 => {
            if (native.target_id == 0 or text.len > Input.max_composition_bytes) {
                return error.InvalidNativeAccessibility;
            }

            const action = std.enums.fromInt(AccessibilityAction.Action, native.code) orelse return error.InvalidNativeAccessibility;
            if (action == .replace_range) {
                try replacementRange(native);
                if (native.revision == 0 or native.replacement_start == std.math.maxInt(u32)) {
                    return error.InvalidNativeAccessibility;
                }
            }

            return .{ .accessibility = .{ .target_id = native.target_id, .generation = native.generation, .revision = native.revision, .action = action, .text = text, .selection_start = native.selection_start, .selection_end = native.selection_end, .replacement_start = native.replacement_start, .replacement_end = native.replacement_end } };
        },
        11 => {
            if (native.target_id == 0 or text.len != 0 or native.replacement_start > Input.max_composition_bytes or native.replacement_end > Input.max_composition_bytes) {
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

    if (native.replacement_start > native.replacement_end or native.replacement_end > Input.max_composition_bytes) {
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
