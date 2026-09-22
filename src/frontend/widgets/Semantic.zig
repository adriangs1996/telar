const core = @import("telar-core");
const CursorType = @import("Cursor.zig");
const Semantic = @This();

area: core.Rect,
focused_card: ?core.Rect = null,
provider_marks: [core.max_agent_snapshot_entries]ProviderMark = undefined,
provider_mark_count: u8 = 0,
list_area: core.Rect = .{},
cursor: ?CursorType = null,

pub const ProviderMark = @import("ProviderMark.zig");

pub fn addProviderMark(semantic: *Semantic, mark: ProviderMark) void {
    if (semantic.provider_mark_count == semantic.provider_marks.len) {
        return;
    }
    semantic.provider_marks[semantic.provider_mark_count] = mark;
    semantic.provider_mark_count += 1;
}
