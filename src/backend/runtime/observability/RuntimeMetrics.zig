const TimingType = @import("telar-core").Timing;
const RuntimeMetrics = @This();

started_ns: u64,
client_messages: u64 = 0,
stale_client_messages: u64 = 0,
stale_pane_events: u64 = 0,
geometry_rejections: u64 = 0,
input_events: u64 = 0,
input_bytes: u64 = 0,
input_write: TimingType = .{},
pty_events: u64 = 0,
pty_bytes: u64 = 0,
frames: u64 = 0,
frame_bytes: u64 = 0,
frame_cells: u64 = 0,
frame_spans: u64 = 0,
snapshots: u64 = 0,
cursor_only_frames: u64 = 0,
noop_frames: u64 = 0,
damaged_rows: u64 = 0,
diff_scanned_cells: u64 = 0,
coalesced_spans: u64 = 0,
bridged_cells: u64 = 0,
coalesced_bytes_saved: u64 = 0,
folded_pty_events: u64 = 0,
graphics_messages: u64 = 0,
graphics_bytes: u64 = 0,
/// Image transfers whose metadata crossed the transport: the runtime's
/// delivered-images counter, so throughput needs no bytes-per-message
/// heuristics.
graphics_images_sent: u64 = 0,
graphics_placements_sent: u64 = 0,
/// Transfers frozen eagerly at a media-idle boundary rather than by the
/// send loop catching one.
graphics_transfers_staged: u64 = 0,
/// Freezes refused by the client or runtime byte credit. Every such
/// refusal skipped a generation the client never saw.
graphics_stage_blocked: u64 = 0,
/// Send-loop graphics lanes skipped because the pane's media actor was
/// running and no transfer was frozen: work waited on the actor.
graphics_stage_deferred: u64 = 0,
/// Generations the media actor froze into shared objects right after
/// decoding them, with the pixels still hot.
graphics_transfers_prepared: u64 = 0,
/// Transfers that adopted one of those objects instead of copying on the
/// runtime thread.
graphics_transfers_adopted: u64 = 0,
/// Fallback copy of one generation out of live media storage into the
/// transfer, on the runtime thread.
graphics_freeze: TimingType = .{},
media_bytes: u64 = 0,
media_discarded_frames: u64 = 0,
/// Shared frames dropped with no replacement ingested: the pane kept a
/// stale image for that batch. Sustained growth is a frozen picture.
media_unavailable_frames: u64 = 0,
/// Shared frames fed to the media terminal. Moving while the graphics
/// revision stays still isolates a silent emulator load failure.
media_forwarded_frames: u64 = 0,
/// Forwarded shared frames loaded with one copy into a runtime-owned
/// object that doubles as emulator storage and client transfer.
media_direct_frames: u64 = 0,
/// The subset of `media_direct_frames` read from a child's file.
media_file_frames: u64 = 0,
media_resets: u64 = 0,
media_failures: u64 = 0,
/// One media actor batch: shared frame folding, mapping and decoding.
media_ingest: TimingType = .{},
system_sample: TimingType = .{},
system_sample_last_ns: u64 = 0,
decode: TimingType = .{},
ingest: TimingType = .{},
encode: TimingType = .{},
ack: TimingType = .{},
history_captured: u64 = 0,
history_dropped: u64 = 0,
history_candidate_input_bytes: u64 = 0,
history_queries: u64 = 0,
history_query_failures: u64 = 0,
history_observation_resets: u64 = 0,
history_observation_failures: u64 = 0,
agent_process_inspections: u64 = 0,
agent_process_misses: u64 = 0,
proxy_observations: u64 = 0,
client_resyncs: u64 = 0,
