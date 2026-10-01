//! Semantic GUI input. Text and paste borrow UTF-8 bytes only for synchronous
//! dispatch; InputQueue copies them before native callbacks return. Pointer,
//! key and focus events are values. No widget consumes the native C ABI.
const TextInput = @import("TextInput.zig");
const KeyInput = @import("KeyInput.zig");
const PointerEvent = @import("PointerEvent.zig");
const Composition = @import("Composition.zig");
const ScrollEvent = @import("ScrollEvent.zig");
const ClipboardResult = @import("ClipboardResult.zig");
const AccessibilityAction = @import("AccessibilityAction.zig");
const DeleteSurrounding = @import("DeleteSurrounding.zig");
const core = @import("telar-core");
const std = @import("std");

pub const Event = union(enum) {
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

/// Mirrors `TELAR_GUI_CLIPBOARD_CAPACITY`: the UTF-8 bytes one clipboard
/// read, write or native paste carries. Pasting a long log or a file into an
/// agent's prompt fits; a larger paste is refused whole, never cut, since
/// half a pasted command may run.
pub const max_text_bytes = 1024 * 1024;
pub const clipboard_limit = core.Limit.declare("gui.clipboard.max_text_bytes", "clipboard bytes", max_text_bytes);
pub const max_composition_bytes = 4096;

comptime {
    // A selection the runtime copies always fits the host clipboard.
    std.debug.assert(max_text_bytes >= core.max_clipboard_bytes);
}
