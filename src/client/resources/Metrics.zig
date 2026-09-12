const TimingType = @import("telar-core").Timing;
const Metrics = @This();

started_ns: u64,
input_events: u64 = 0,
input_bytes: u64 = 0,
key_lease_overflows: u64 = 0,
server_messages: u64 = 0,
server_bytes: u64 = 0,
graphics_messages: u64 = 0,
graphics_bytes: u64 = 0,
/// Image transfers received from the runtime (headers and shared names).
graphics_images: u64 = 0,
/// Pane images handed to the host as a shared-memory name.
pane_shared_images: u64 = 0,
/// Pane images whose inline transmission closed, compressed or raw.
pane_inline_images: u64 = 0,
/// The subset of `pane_inline_images` shipped as a zlib stream.
pane_compressed_images: u64 = 0,
/// Chunk-emission calls; against `pane_inline_images` this measures the
/// passes-per-image pacing of the transmission budget.
pane_transmission_passes: u64 = 0,
/// Writer passes that advanced an image deflate by at least one slice.
pane_compress_passes: u64 = 0,
frames: u64 = 0,
frame_cells: u64 = 0,
frame_spans: u64 = 0,
snapshots: u64 = 0,
composed_panes: u64 = 0,
composed_cells: u64 = 0,
composed_damage_cells: u64 = 0,
full_compositions: u64 = 0,
flushes: u64 = 0,
scanned_cells: u64 = 0,
flushed_cells: u64 = 0,
flushed_bytes: u64 = 0,
graphics_flushed_bytes: u64 = 0,
pane_graphics_flushed_bytes: u64 = 0,
toast_graphics_flushed_bytes: u64 = 0,
sidebar_graphics_flushed_bytes: u64 = 0,
icon_graphics_flushed_bytes: u64 = 0,
modal_graphics_flushed_bytes: u64 = 0,
pill_graphics_flushed_bytes: u64 = 0,
attachment_graphics_flushed_bytes: u64 = 0,
media_flushes: u64 = 0,
/// Media passes that yielded to a pending cell frame and re-armed a
/// whole pacer interval later.
media_deferrals: u64 = 0,
max_pending_updates: u64 = 0,
mouse_events: u64 = 0,
chrome_scanned_cells: u64 = 0,
chrome_damaged_cells: u64 = 0,
decode: TimingType = .{},
apply: TimingType = .{},
compose: TimingType = .{},
ack_enqueue: TimingType = .{},
input_enqueue: TimingType = .{},
flush: TimingType = .{},
media_flush: TimingType = .{},
draw_lateness: TimingType = .{},
paced_interval: TimingType = .{},
/// Time between consecutive pane images handed to the host.
pane_present_interval: TimingType = .{},
