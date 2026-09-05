//! Attachment identities, bounds and owned capture values.

const std = @import("std");
const core = @import("telar-core");
const Io = std.Io;
const schema = core.schema;
const ui = core.ui;
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

/// The placeholder's first word. Claude and Codex word-wrap `[Image #N]` at
/// the space after it, so a marker may end on the row below its head.
pub const Target = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,

    pub fn validate(target: Target) !void {
        if (target.pane_id == .invalid or target.pane_generation == 0) {
            return error.InvalidAttachmentTarget;
        }
    }
};

pub const CaptureRequest = struct {
    target: Target,
    sequence: u64,
    marker_policy: MarkerPolicy = .ordered,
};

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

pub const Capture = struct {
    request: CaptureRequest,
    png: []u8,
    width: u32,
    height: u32,

    pub fn deinit(capture: *Capture, gpa: std.mem.Allocator) void {
        if (capture.png.len != 0) {
            std.crypto.secureZero(u8, capture.png);
            gpa.free(capture.png);
        }
        gpa.destroy(capture);
    }
};

/// Owns only the result pointer that can outlive a cancelled capture worker.
/// The client model owns the active capture identity and target.
pub const CaptureResources = struct {
    orphan: ?*Capture = null,

    /// Transfers one completed worker result to the client event handler.
    ///
    /// ```zig
    /// const owned = resources.take(completed);
    /// ```
    pub fn take(resources: *CaptureResources, capture: *Capture) *Capture {
        std.debug.assert(resources.orphan == capture);
        resources.orphan = null;
        return capture;
    }

    /// Frees a result published before its worker was cancelled.
    ///
    /// ```zig
    /// defer resources.deinit(gpa);
    /// ```
    pub fn deinit(resources: *CaptureResources, gpa: std.mem.Allocator) void {
        if (resources.orphan) |capture| {
            capture.deinit(gpa);
        }

        resources.* = .{};
    }
};

pub const Id = enum(u64) {
    invalid = 0,
    _,
};

pub const Item = struct {
    id: Id,
    width: u32,
    height: u32,
};

pub const Snapshot = struct {
    items: [max_items]Item = undefined,
    len: u8 = 0,
    modal: ?Id = null,

    pub fn slice(snapshot: *const Snapshot) []const Item {
        return snapshot.items[0..snapshot.len];
    }
};

pub const MarkerScreen = struct {
    buffer: *const ui.Buffer,
    cursor: schema.frame.Cursor,
};

pub const MarkerDeletion = enum {
    backward,
    forward,
};

pub const MarkerRemoval = struct {
    direction: enum {
        left,
        right,
    },
    steps: u8,
    deletion: MarkerDeletion,
    /// Deletion keys needed: one for an atomic placeholder, one per grapheme
    /// for a pasted path.
    deletions: u8 = 1,

    pub fn keyCount(removal: MarkerRemoval) usize {
        return @as(usize, removal.steps) * 2 + removal.deletions;
    }
};

/// Names the deletion being probed for a preview that has no slot yet.
pub const DeletionProbe = struct {
    deletion: MarkerDeletion,
    policy: MarkerPolicy = .ordered,
};

pub const PendingDeletion = struct {
    target: Target,
    frames: u8,
};

pub const PlanItem = struct {
    id: Id,
    area: ui.Rect,
};

pub const Plan = struct {
    thumbnails: [max_items]PlanItem = undefined,
    thumbnail_count: u8 = 0,
    modal: ?PlanItem = null,

    pub fn thumbnailSlice(plan: *const Plan) []const PlanItem {
        return plan.thumbnails[0..plan.thumbnail_count];
    }
};
