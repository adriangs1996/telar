pub const Item = union(enum) {
    release_recovery,
    pointer: @import("input/PointerSample.zig"),
    key: @import("input/KeyInput.zig"),
    text: @import("input/TextCommit.zig"),
    paste_start,
    paste_text: @import("PasteChunk.zig"),
    paste_finish,
    scroll: @import("input/ScrollSample.zig"),
    owned_small: u8,
    owned_large: u8,
    composition_cancel: @import("input/Composition.zig"),
};
