const core = @import("telar-core");
const Projection = @This();

buffer: *const core.Buffer,
damaged_rows: []const bool,
cursor: core.Cursor,
scroll: core.Scroll,

text_metadata: core.TextMetadataView,
text_revision: u64,
