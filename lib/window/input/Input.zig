//! Semantic input shared by windows and GUI consumers. getNextEvent lends text
//! until its next call; the legacy synchronous callback copies text immediately.
//! Pointer, key and focus events are values. No widget consumes the native ABI.
const decode_input = @import("decode_input.zig");
const native_input = @import("NativeInput.zig");
const TextInput = @import("TextInput.zig");
const KeyInput = @import("KeyInput.zig");
const PointerEvent = @import("PointerEvent.zig");
const Composition = @import("Composition.zig");
const ScrollEvent = @import("ScrollEvent.zig");
const ClipboardResult = @import("ClipboardResult.zig");
const AccessibilityAction = @import("AccessibilityAction.zig");
const DeleteSurrounding = @import("DeleteSurrounding.zig");

pub const Input = union(enum) {
    pub fn fromNative(native: native_input.NativeInput) !Input {
        return decode_input.decode(native);
    }

    text: TextInput,
    paste: []const u8,
    key: KeyInput,
    pointer: PointerEvent,
    focus: bool,
    composition: Composition,
    scroll: ScrollEvent,
    clipboard: ClipboardResult,
    accessibility: AccessibilityAction,
    delete_surrounding: DeleteSurrounding,

    pub fn isScrollOrPointerBegin(self: *const Input) bool {
        return self.isScroll() or (self.isPointer() and (self.pointer.kind == .press or self.pointer.kind == .scroll_up or self.pointer.kind == .scroll_down));
    }

    pub fn isScroll(self: *const Input) bool {
        return self.* == .scroll;
    }

    pub fn isPointerPress(self: *const Input) bool {
        return self.isPointer() and self.pointer.kind == .press;
    }

    pub fn isPointer(self: *const Input) bool {
        return self.* == .pointer;
    }

    pub fn isFocusNotFocused(self: *const Input) bool {
        return self.* == .focus and !self.focus;
    }

    pub fn isWriteClipboardContent(self: *const Input) bool {
        return self.isClipboard() and self.clipboard.operation == .write;
    }

    pub fn isClipboard(self: *const Input) bool {
        return self.* == .clipboard;
    }

    pub fn isAccessibility(self: *const Input) bool {
        return self.* == .accessibility;
    }
    pub fn payload(self: Input) []const u8 {
        return switch (self) {
            .text => |value| value.bytes,
            .paste => |value| value,
            .composition => |value| value.text,
            .clipboard => |value| value.text,
            .accessibility => |value| value.text,
            else => "",
        };
    }

    pub fn withPayload(self: Input, bytes: []const u8) Input {
        var result = self;
        switch (result) {
            .text => |*value| value.bytes = bytes,
            .paste => |*value| value.* = bytes,
            .composition => |*value| value.text = bytes,
            .clipboard => |*value| value.text = bytes,
            .accessibility => |*value| value.text = bytes,
            else => {},
        }

        return result;
    }

    pub const max_text_bytes = 1024 * 1024;
    pub const max_composition_bytes = 4096;
};
