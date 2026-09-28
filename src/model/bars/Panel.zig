//! The panel a client shows above its bottom bar. Disposable client state:
//! killing the client loses which panel was open and nothing else.
const LocalTime = @import("../state/LocalTime.zig");
const BarComponent = @import("BarComponent.zig");
const PanelStatus = @import("PanelStatus.zig").PanelStatus;
const PanelTarget = @import("PanelTarget.zig").PanelTarget;
const model = @import("model.zig");
const Panel = @This();

target: PanelTarget = .none,
anchor: ?BarComponent = null,
content: model.PanelContent = .{},
status: PanelStatus = .loading,
/// Local time of the last render that produced content.
updated: ?LocalTime = null,
/// Advances on every opening, so a render started for an earlier opening
/// is discarded when it completes.
opening: u32 = 0,

pub fn isOpen(self: *const Panel) bool {
    return self.target != .none;
}

/// The configured panel shown, if the open panel is one.
/// Example: `const index = panel.configured() orelse return;`
pub fn configured(self: *const Panel) ?u8 {
    return switch (self.target) {
        .configured => |index| index,
        else => null,
    };
}
