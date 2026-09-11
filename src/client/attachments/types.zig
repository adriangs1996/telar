//! Attachment identities, bounds and owned capture values.

const path_marker = @import("path_marker.zig");

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

/// How the child's prompt identifies one pasted image.
///
/// - `ordered`: Codex renumbers `[Image #N]` after deletion, so the preview's
///   shelf position is its marker.
/// - `stable_number`: Claude keeps increasing `[Image #N]`, so the number
///   rendered for each preview is learned and retained.
/// - `pasted_path`: Pi inserts `<tmpdir>/pi-clipboard-<uuid>.<ext>` as plain
///   text, so the file UUID is learned and the whole path is the marker.
pub const MarkerPolicy = enum {
    ordered,
    stable_number,
    pasted_path,

    pub fn learnsIdentity(policy: MarkerPolicy) bool {
        return policy != .ordered;
    }
};

pub const MarkerIdentity = union(enum) {
    number: u16,
    path: path_marker.Uuid,
};

pub const Id = enum(u64) {
    invalid = 0,
    _,
};

pub const MarkerDeletion = enum {
    backward,
    forward,
};
