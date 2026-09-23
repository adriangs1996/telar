const core = @import("telar-core");
const data = @import("model");
const Credit = @import("Credit.zig");
/// The client's retained-graphics store as controllers see it. Each adapter
/// instantiates the shared `GenericResourceStore` with its own per-entry
/// delivery state and binds it here; controllers never learn that type.
const GraphicsRetention = @This();

context: *anyopaque,
apply_fn: *const fn (*anyopaque, data.PaneGraphicsCommand) anyerror!void,
clear_pane_fn: *const fn (*anyopaque, core.PaneId) void,
set_pane_visible_fn: *const fn (*anyopaque, core.PaneId, bool) anyerror!void,
pane_visible_fn: *const fn (*anyopaque, core.PaneId) bool,
has_pane_graphics_fn: *const fn (*anyopaque, core.PaneId) bool,
ingress_version_fn: *const fn (*anyopaque) u64,
peek_credit_fn: *const fn (*anyopaque) ?Credit,
consume_credit_fn: *const fn (*anyopaque, Credit) void,

/// Applies one decoded graphics message. Example: `try client.graphics.apply(command);`.
pub fn apply(self: GraphicsRetention, command: data.PaneGraphicsCommand) !void {
    return self.apply_fn(self.context, command);
}

/// Example: `client.graphics.clearPane(pane_id);`.
pub fn clearPane(self: GraphicsRetention, pane_id: core.PaneId) void {
    self.clear_pane_fn(self.context, pane_id);
}

/// Example: `try client.graphics.setPaneVisible(pane_id, false);`.
pub fn setPaneVisible(self: GraphicsRetention, pane_id: core.PaneId, visible: bool) !void {
    return self.set_pane_visible_fn(self.context, pane_id, visible);
}

pub fn paneVisible(self: GraphicsRetention, pane_id: core.PaneId) bool {
    return self.pane_visible_fn(self.context, pane_id);
}

pub fn hasPaneGraphics(self: GraphicsRetention, pane_id: core.PaneId) bool {
    return self.has_pane_graphics_fn(self.context, pane_id);
}

/// Advances whenever retained graphics change. Example: `const before = client.graphics.ingressVersion();`.
pub fn ingressVersion(self: GraphicsRetention) u64 {
    return self.ingress_version_fn(self.context);
}

/// Example: `while (client.graphics.peekCredit()) |credit| { ... client.graphics.consumeCredit(credit); }`.
pub fn peekCredit(self: GraphicsRetention) ?Credit {
    return self.peek_credit_fn(self.context);
}

pub fn consumeCredit(self: GraphicsRetention, credit: Credit) void {
    self.consume_credit_fn(self.context, credit);
}
