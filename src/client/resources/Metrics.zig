//! What the client counts for its diagnostics log; `client_telemetry`
//! writes it once a second in builds with diagnostics.
const core = @import("telar-core");
const Metrics = @This();

started_ns: u64,
input_events: u64 = 0,
input_bytes: u64 = 0,
key_lease_overflows: u64 = 0,
mouse_events: u64 = 0,
server_messages: u64 = 0,
server_bytes: u64 = 0,
graphics_messages: u64 = 0,
graphics_bytes: u64 = 0,
/// Image transfers received from the runtime (headers and shared names).
graphics_images: u64 = 0,
frames: u64 = 0,
frame_cells: u64 = 0,
frame_spans: u64 = 0,
snapshots: u64 = 0,
decode: core.Timing = .{},
apply: core.Timing = .{},
input_enqueue: core.Timing = .{},
/// Images a window's renderer turned into textures, and how long each took
/// from the upload request to its report.
graphics_textures: u64 = 0,
graphics_upload: core.Timing = .{},
/// Image generations a window drew for the first time, and the bytes its
/// textures hold.
graphics_presented: u64 = 0,
graphics_gpu_bytes: usize = 0,
/// Frames a window delivered to its display, so a flood shows how close the
/// window came to its display's rate.
presentations: u64 = 0,
/// Graphics snapshots requested to recover a broken revision.
graphics_resyncs: u64 = 0,
