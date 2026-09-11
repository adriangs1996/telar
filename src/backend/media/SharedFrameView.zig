/// One complete shared-memory frame the filter selected, handed to a sink
/// that can load it without the emulator's parser. `bytes` spans the whole
/// synchronized envelope; the APC command sits at `apc_start..apc_end`.
///
/// ```zig
/// pub fn observeSharedFrame(sink: *Sink, frame: SharedFrameView) bool
/// ```
const SharedFrameView = @This();
const core = @import("telar-core");
const source_namespace = @import("root.zig");
bytes: []const u8,
apc_start: usize,
apc_end: usize,
encoded_name: []const u8,
image_id: u32,
placement_id: u32,
format: core.graphics.Format,
width: u32,
height: u32,
byte_len: usize,
medium: source_namespace.Medium,
