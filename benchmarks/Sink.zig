const backend = @import("telar-backend");
const Sink = @This();

pipeline: *backend.Pipeline,

pub fn observe(sink: *Sink, bytes: []const u8) void {
    sink.pipeline.stream.nextSlice(bytes);
}

/// The bare pipeline measures the emulator's own shared-memory load;
/// the pane-level single-copy path is exercised by the runtime tests.
pub fn observeSharedFrame(_: *Sink, _: backend.SharedFrameView) bool {
    return false;
}

pub fn observeFileQuery(_: *Sink, _: backend.FileQueryView) bool {
    return false;
}
