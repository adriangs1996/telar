const Semantic = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("sidebar.zig");
const widget = @import("context_support.zig");
area: ui.Rect,
focused_card: ?ui.Rect = null,
provider_marks: [source_namespace.max_provider_marks]ProviderMark = undefined,
provider_mark_count: u8 = 0,
list_area: ui.Rect = .{},
cursor: ?widget.Cursor = null,

pub const ProviderMark = struct {
    area: ui.Rect,
    provider: source_namespace.schema.AgentProvider,
};

pub fn addProviderMark(semantic: *Semantic, mark: ProviderMark) void {
    if (semantic.provider_mark_count == semantic.provider_marks.len) {
        return;
    }
    semantic.provider_marks[semantic.provider_mark_count] = mark;
    semantic.provider_mark_count += 1;
}
