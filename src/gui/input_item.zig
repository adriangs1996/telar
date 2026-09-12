pub const Item = union(enum) {
    key: @import("telar-client").Key,
    paste_start,
    paste_text: @import("PasteChunk.zig"),
    paste_finish,
};
