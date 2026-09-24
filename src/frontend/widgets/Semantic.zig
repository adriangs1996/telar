const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const Semantic = @This();

area: cellgrid.Rect,
focused_card: ?cellgrid.Rect = null,
provider_marks: [core.max_agent_snapshot_entries]ProviderMark = undefined,
provider_mark_count: u8 = 0,
list_area: cellgrid.Rect = .{},
cursor: ?Cursor = null,

pub const ProviderMark = @import("ProviderMark.zig");

pub fn addProviderMark(self: *Semantic, mark: ProviderMark) void {
    if (self.provider_mark_count == self.provider_marks.len) {
        return;
    }
    self.provider_marks[self.provider_mark_count] = mark;
    self.provider_mark_count += 1;
}
