//! Queue depth, its high-water mark and the items dropped at publication.
const QueueMetrics = @This();

queued: u64,
high_water: u64,
dropped: u64,
