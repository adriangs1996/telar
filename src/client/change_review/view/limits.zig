const core = @import("telar-core");

/// Files one review edition indexes; the rest of the edition is left out
/// of the view and reported.
pub const files = 128;
/// Numbered rows one review edition indexes, enough for most editions at
/// `max_patch_bytes`; the rest is left out of the view and reported.
pub const lines = 4096;
pub const comments = 32;
pub const comment_bytes = 2048;
pub const search_bytes = 256;

pub const files_limit = core.Limit.declare("change_review.view_files", "files", files);
pub const lines_limit = core.Limit.declare("change_review.view_lines", "diff rows", lines);
