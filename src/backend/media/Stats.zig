const Stats = @This();

output_bytes: u64 = 0,
/// Shared frames folded because a newer frame of the same placement was
/// available in the batch: latest-wins working as designed.
discarded_frames: u64 = 0,
/// Shared frames dropped because no frame of their placement passed the
/// availability probe: the producer's object was gone or over the limit.
/// Sustained growth here means the pane shows a stale image.
unavailable_frames: u64 = 0,
/// Shared frames actually fed to the media terminal. Together with the
/// two counters above this partitions every frame, so `forwarded` moving
/// while the graphics revision stays still isolates a silent load
/// failure inside the emulator.
forwarded_frames: u64 = 0,
/// Wall time the media actor spent on this batch, including every shared
/// frame it mapped, copied into pane storage and unlinked.
elapsed_ns: u64 = 0,
/// Generations the actor froze into runtime-owned shared objects for
/// local clients to adopt without another copy.
prepared_frames: u64 = 0,
/// Shared frames copied once, from the child's object straight into the
/// runtime-owned object that then serves as emulator storage.
direct_frames: u64 = 0,
/// The subset of `direct_frames` whose pixels came from a child file.
file_frames: u64 = 0,
reset: bool = false,
failed: bool = false,
