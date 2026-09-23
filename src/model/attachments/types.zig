//! Attachment identities, bounds and owned capture values.

pub const max_items: usize = 4;
pub const max_source_bytes: usize = 32 * 1024 * 1024;
pub const max_png_bytes: usize = 16 * 1024 * 1024;
pub const max_pixels: u64 = 16 * 1024 * 1024;
pub const max_retained_bytes: usize = 32 * 1024 * 1024;
pub const max_marker_navigation_steps: u8 = 120;
/// Keys one marker removal may enqueue as a single pane-input transaction.
/// The pane-input boundary encodes at most this many keys per transaction.
pub const max_removal_keys: usize = 256;
/// Committed frames inspected for a marker's disappearance after a deletion
/// key. The child may publish an unrelated frame before it redraws its editor.
pub const deletion_watch_frames: u8 = 3;

pub const Id = @import("../types/AttachmentId.zig").AttachmentId;

pub const MarkerDeletion = @import("../types/AttachmentMarkerDeletion.zig").AttachmentMarkerDeletion;
