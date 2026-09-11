const Sources = @import("Sources.zig");
const goto_picker = @import("goto_picker.zig");
const score_module = @import("telar-core").score;
const Scorer = @This();

sources: Sources,
query: []const u8,
label: [goto_picker.max_label_bytes]u8 = undefined,

pub fn scoreItem(scorer: *Scorer, item: goto_picker.Item) ?u32 {
    return score_module(goto_picker.describe(scorer.sources, item, &scorer.label), scorer.query);
}
