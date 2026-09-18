//! Semantic GUI input. Text and paste borrow UTF-8 bytes only for synchronous
//! dispatch; NativeInput copies them before native callbacks return. Pointer,
//! key and focus events are values. No widget consumes the native C ABI.
pub const Event = union(enum) {
    text: @import("TextInput.zig"),
    paste: []const u8,
    key: @import("KeyInput.zig"),
    pointer: @import("PointerEvent.zig"),
    focus: bool,
    composition: @import("Composition.zig"),
    scroll: @import("ScrollEvent.zig"),
    clipboard: @import("ClipboardResult.zig"),
    accessibility: @import("AccessibilityAction.zig"),
    delete_surrounding: @import("DeleteSurrounding.zig"),

    pub fn isScrollOrPointerBegin(self: *const Event) bool {
        return self.isScroll() or (self.isPointer() and (self.pointer.kind == .press or self.pointer.kind == .scroll_up or self.pointer.kind == .scroll_down));
    }

    pub fn isScroll(self: *const Event) bool {
        return self.* == .scroll;
    }

    pub fn isPointerPress(self: *const Event) bool {
        return self.isPointer() and self.pointer.kind == .press;
    }

    pub fn isPointer(self: *const Event) bool {
        return self.* == .pointer;
    }

    pub fn isFocusNotFocused(self: *const Event) bool {
        return self.* == .focus and !self.focus;
    }

    pub fn isWriteClipboardContent(self: *const Event) bool {
        return self.isClipboard() and self.clipboard.operation == .write;
    }

    pub fn isClipboard(self: *const Event) bool {
        return self.* == .clipboard;
    }

    pub fn isAccessibility(self: *const Event) bool {
        return self.* == .accessibility;
    }
};

pub const max_text_bytes = 64 * 1024;
pub const max_composition_bytes = 4096;
