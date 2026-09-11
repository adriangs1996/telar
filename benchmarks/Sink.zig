const PipelineType = @import("telar-backend").Pipeline;
const SharedFrameViewType = @import("telar-backend").SharedFrameView;
const FileQueryViewType = @import("telar-backend").FileQueryView;
const Sink = @This();

pipeline: *PipelineType,

pub fn observe(sink: *Sink, bytes: []const u8) void {
    sink.pipeline.stream.nextSlice(bytes);
}

/// The bare pipeline measures the emulator's own shared-memory load;
/// the pane-level single-copy path is exercised by the runtime tests.
pub fn observeSharedFrame(_: *Sink, _: SharedFrameViewType) bool {
    return false;
}

pub fn observeFileQuery(_: *Sink, _: FileQueryViewType) bool {
    return false;
}
