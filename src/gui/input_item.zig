pub const Item = union(enum) {
    release_recovery,
    pointer: @import("input/PointerSample.zig"),
    key: @import("telar-client").Key,
    paste_start,
    paste_text: @import("PasteChunk.zig"),
    paste_finish,
};
