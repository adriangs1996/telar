const Scorer = @This();
const Sources = @import("Sources.zig");
const source_namespace = @import("goto_picker.zig");
sources: Sources,
query: []const u8,
label: [source_namespace.max_label_bytes]u8 = undefined,

pub fn scoreItem(scorer: *Scorer, item: source_namespace.Item) ?u32 {
    return source_namespace.score(source_namespace.describe(scorer.sources, item, &scorer.label), scorer.query);
}
