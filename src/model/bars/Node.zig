//! One component of a bar slot, a tooltip or a panel. Nodes are stored in
//! document order and a child names its container by index, so a component
//! list is one flat bounded value with no pointers.
const ContentRange = @import("ContentRange.zig");
const Mark = @import("Mark.zig").Mark;
const MetricName = @import("MetricName.zig").MetricName;
const NodeKind = @import("NodeKind.zig").NodeKind;
const Style = @import("Style.zig");
const Tone = @import("Tone.zig").Tone;
const ui_icons = @import("../layout/icons.zig");
const Node = @This();

pub const no_parent: u8 = 0xff;
pub const no_action: u8 = 0xff;
/// The most components one list can index: `no_parent` and `no_action`
/// take the last byte value.
pub const max_list_nodes = no_parent - 1;
/// Values one sparkline keeps: two minutes of one-second samples.
pub const max_samples = 120;
pub const default_priority: u8 = 50;
pub const max_priority: u8 = 100;
/// Meter values and markers are stored in thousandths of the full scale.
pub const full_scale: u16 = 1000;
const percent_scale: u32 = 100;

kind: NodeKind = .label,
parent: u8 = no_parent,
/// Belongs to the tooltip of its parent group instead of its bar row.
in_tooltip: bool = false,
/// Label, badge, heading and button text; a meter's label; a kv key; a
/// callout title; a clock's format; an icon's glyph.
text: ContentRange = .{},
/// A meter's displayed value, a kv value, a meter row or callout detail.
detail: ContentRange = .{},
/// An `http(s)` destination opened when the component is clicked.
url: ContentRange = .{},
samples: ContentRange = .{},
icon: ?ui_icons.Icon = null,
mark: ?Mark = null,
metric: MetricName = .cpu,
tone: Tone = .neutral,
style: Style = .{},
value: u16 = 0,
marker: ?u16 = null,
priority: u8 = default_priority,
primary: bool = false,
action: u8 = no_action,

/// The priority the fitter compares; attention raises it.
/// Example: `if (node.effectivePriority() < lowest) lowest = node.effectivePriority();`
pub fn effectivePriority(self: Node) u8 {
    return self.priority +| self.tone.priorityBonus();
}

/// Whether a click on the component does something.
/// Example: `if (node.isActionable()) try bands.add(...);`
pub fn isActionable(self: Node) bool {
    return self.action != no_action or !self.url.isEmpty();
}

/// Whether the component is a top-level item of its row or panel.
pub fn isRoot(self: Node) bool {
    return self.parent == no_parent;
}

/// The value as a whole percentage, for labels and cell meters.
/// Example: `const percent = node.percent(); // 42`
pub fn percent(self: Node) u8 {
    return @intCast((@as(u32, self.value) * percent_scale + full_scale / 2) / full_scale);
}
