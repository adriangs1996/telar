//! Attachment identities, bounds and owned capture values.
const std = @import("std");
const core = @import("telar-core");
const input_limits = @import("../input/limits.zig");

/// Previews one window keeps; a fifth capture evicts the oldest and reports
/// `attachments.max_items`.
pub const max_items: usize = 4;
pub const items_limit = core.Limit.declare("attachments.max_items", "previews", max_items);
/// Clipboard bytes the capture worker reads before it encodes a PNG.
pub const max_source_bytes: usize = 32 * 1024 * 1024;
pub const source_bytes_limit = core.Limit.declare("attachments.max_source_bytes", "bytes", max_source_bytes);
/// Bytes of one captured PNG: an 8K screenshot encodes to tens of MiB.
pub const max_png_bytes: usize = 32 * 1024 * 1024;
pub const png_bytes_limit = core.Limit.declare("attachments.max_png_bytes", "bytes", max_png_bytes);
/// Pixels of one captured image: a 6K display (6016 x 3384, 20.4 Mpx) and 8K
/// UHD (7680 x 4320, 33.2 Mpx) fit. The capture worker decodes the PNG once
/// for its previews, holding 4 bytes a pixel of RGBA and Wuffs's work buffer
/// of one filter byte a row and 3 to 8 bytes a pixel while it runs: at this
/// bound 252 MiB for 8-bit RGB, 288 MiB for 8-bit RGBA and 432 MiB at worst
/// (16-bit RGBA).
pub const max_pixels: u64 = 36 * 1024 * 1024;
pub const pixels_limit = core.Limit.declare("attachments.max_pixels", "pixels", max_pixels);
/// PNG bytes the previews keep together; the oldest are evicted past it and
/// `attachments.max_retained_bytes` is reported.
pub const max_retained_bytes: usize = 32 * 1024 * 1024;
pub const retained_bytes_limit = core.Limit.declare("attachments.max_retained_bytes", "bytes", max_retained_bytes);
/// Editor steps between the cursor and a placeholder marker that dismissing
/// its preview may take: twice this plus the deletion fits
/// `max_removal_keys`.
pub const max_marker_navigation_steps: u8 = 120;
pub const marker_navigation_steps_limit = core.Limit.declare("attachments.max_marker_navigation_steps", "editor steps", max_marker_navigation_steps);
/// Keys one marker removal may enqueue as a single pane-input transaction.
/// The pane-input boundary encodes at most this many keys per transaction,
/// so a Pi path longer than about 250 cells cannot be dismissed with one.
pub const max_removal_keys: usize = input_limits.max_synthetic_keys;
pub const removal_keys_limit = core.Limit.declare("attachments.max_removal_keys", "keys", max_removal_keys);
/// Committed frames inspected for a marker's disappearance after a deletion
/// key. The child may publish an unrelated frame before it redraws its editor.
pub const deletion_watch_frames: u8 = 3;

comptime {
    // One image of every bound fits the retained bytes, and a capture at
    // the PNG bound can come from a source at its bound.
    std.debug.assert(max_retained_bytes >= max_png_bytes);
    std.debug.assert(max_png_bytes <= max_source_bytes);
    std.debug.assert(2 * @as(usize, max_marker_navigation_steps) + 1 <= max_removal_keys);
}

pub const Id = @import("AttachmentId.zig").AttachmentId;

pub const MarkerDeletion = @import("AttachmentMarkerDeletion.zig").AttachmentMarkerDeletion;
