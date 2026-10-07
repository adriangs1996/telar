const Window = @import("telar-window");
const PointerSample = @import("input/PointerSample.zig");
const KeyInput = @FieldType(Window.Input, "key");
const TextCommit = @import("input/TextCommit.zig");
const PasteChunk = @import("PasteChunk.zig");
const ScrollSample = @import("input/ScrollSample.zig");
const Composition = @FieldType(Window.Input, "composition");
const HeldText = @import("input/HeldText.zig");

pub const Admission = enum { accepted, recovery };

pub const Item = union(enum) {
    release_recovery,
    pointer: PointerSample,
    key: KeyInput,
    text: TextCommit,
    paste_start,
    paste_text: PasteChunk,
    paste_finish,
    scroll: ScrollSample,
    owned_small: u8,
    owned_large: u8,
    /// A committed text longer than the ring takes a scalar at a time.
    text_block: HeldText,
    /// A native paste longer than the ring takes a chunk at a time.
    paste_block: HeldText,
    composition_cancel: Composition,
};
