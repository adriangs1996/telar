//! Bounded review wire values shared by runtime and presentation.
pub const max_patch_bytes = 48 * 1024;
pub const max_sample_bytes = 24 * 1024;
pub const max_comments = 32;
pub const max_comment_bytes = 2048;
pub const max_path_bytes = 4096;
pub const max_identity_bytes = 128;
pub const max_feedback_bytes = 8 * 1024;
pub const Side = enum(u8) { before, after };
pub const Source = enum(u8) { provider_patch, observed_snapshot };
pub const SamplePhase = enum(u8) { before, after };
pub const Delivery = enum(u8) { idle, pending, delivered };
pub const Action = enum(u8) { save_comment, delete_comment, submit, mark_reviewed, feedback, ack_feedback };
