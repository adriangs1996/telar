//! Bounded review wire values shared by runtime and presentation.
const Limit = @import("Limit.zig");

/// Largest unified diff one edition keeps; a longer one keeps its first
/// whole files and hunks and the first lines of the hunk that crosses it.
pub const max_patch_bytes = 128 * 1024;
/// Largest file the hook samples before and after an edit; a larger file is
/// skipped and reported.
pub const max_sample_bytes = 128 * 1024;
pub const max_comments = 32;
pub const max_comment_bytes = 2048;
pub const max_path_bytes = 4096;
pub const max_identity_bytes = 128;
/// Largest formatted feedback; comments that do not fit are left out and
/// counted in its last line.
pub const max_feedback_bytes = 32 * 1024;
/// Longest status line of a snapshot.
pub const max_status_bytes = 512;

pub const patch_limit = Limit.declare("review.max_patch_bytes", "diff bytes", max_patch_bytes);
pub const sample_limit = Limit.declare("review.max_sample_bytes", "file bytes", max_sample_bytes);
pub const feedback_limit = Limit.declare("review.max_feedback_bytes", "feedback bytes", max_feedback_bytes);
pub const comments_limit = Limit.declare("review.max_comments", "comments", max_comments);

/// Fixed fields of one encoded sample: its tag, three ids, three one-byte
/// values and four lengths, rounded up.
const sample_fields_bytes = 64;
/// Fixed fields of one encoded snapshot: its tag, ids, revisions, flags and
/// lengths, rounded up.
const snapshot_fields_bytes = 256;
/// Fixed fields of one encoded comment: its id, lines, side, draft flag and
/// two lengths, rounded up.
const comment_fields_bytes = 32;

/// Bytes of the largest `report_change_review_sample`.
pub const max_sample_message_bytes = sample_fields_bytes + 2 * max_identity_bytes + max_path_bytes + max_sample_bytes;
/// Bytes of the largest `change_review_snapshot`.
pub const max_snapshot_message_bytes = snapshot_fields_bytes + max_identity_bytes + max_patch_bytes + max_feedback_bytes + max_status_bytes + max_comments * (comment_fields_bytes + max_path_bytes + max_comment_bytes);

pub const Side = enum(u8) { before, after };
pub const Source = enum(u8) { provider_patch, observed_snapshot };
pub const SamplePhase = enum(u8) { before, after };
pub const Delivery = enum(u8) { idle, pending, delivered };
pub const Action = enum(u8) { save_comment, delete_comment, submit, mark_reviewed, feedback, ack_feedback };
