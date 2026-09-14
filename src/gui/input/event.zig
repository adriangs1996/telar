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
};

pub const max_text_bytes = 64 * 1024;
pub const max_composition_bytes = 4096;
