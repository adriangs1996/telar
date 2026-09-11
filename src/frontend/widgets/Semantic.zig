const ProviderMarkType = @import("ProviderMark.zig");
const RectType = @import("telar-core").Rect;
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const CursorType = @import("Cursor.zig");
const Semantic = @This();

area: RectType,
focused_card: ?RectType = null,
provider_marks: [max_agent_snapshot_entries]ProviderMarkType = undefined,
provider_mark_count: u8 = 0,
list_area: RectType = .{},
cursor: ?CursorType = null,

pub const ProviderMark = @import("ProviderMark.zig");

pub fn addProviderMark(semantic: *Semantic, mark: ProviderMarkType) void {
    if (semantic.provider_mark_count == semantic.provider_marks.len) {
        return;
    }
    semantic.provider_marks[semantic.provider_mark_count] = mark;
    semantic.provider_mark_count += 1;
}
