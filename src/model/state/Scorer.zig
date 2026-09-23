const core = @import("telar-core");
const Sources = @import("Sources.zig");
const goto_picker = @import("goto_picker.zig");
const Scorer = @This();

sources: Sources,
query: []const u8,
label: [goto_picker.max_label_bytes]u8 = undefined,

pub fn scoreItem(self: *Scorer, item: goto_picker.Item) ?u32 {
    return core.score(goto_picker.describe(self.sources, item, &self.label), self.query);
}
