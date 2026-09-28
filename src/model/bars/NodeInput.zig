//! Borrowed values for one component before a component list copies them.
const Action = @import("../input/action.zig").Action;
const Mark = @import("Mark.zig").Mark;
const MetricName = @import("MetricName.zig").MetricName;
const Node = @import("Node.zig");
const NodeKind = @import("NodeKind.zig").NodeKind;
const Style = @import("Style.zig");
const Tone = @import("Tone.zig").Tone;
const ui_icons = @import("../layout/icons.zig");
const NodeInput = @This();

kind: NodeKind,
parent: u8 = Node.no_parent,
in_tooltip: bool = false,
text: []const u8 = "",
detail: []const u8 = "",
url: []const u8 = "",
samples: []const u8 = &.{},
icon: ?ui_icons.Icon = null,
mark: ?Mark = null,
metric: MetricName = .cpu,
tone: Tone = .neutral,
style: Style = .{},
value: u16 = 0,
marker: ?u16 = null,
priority: u8 = Node.default_priority,
primary: bool = false,
action: ?Action = null,
