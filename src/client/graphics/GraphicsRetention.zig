const PaneIdType = @import("telar-core").PaneId;
const CommandType = @import("../application/panes/pane_graphics.zig").Command;
const CreditType = @import("Credit.zig");
/// The client's retained-graphics store as controllers see it. Each adapter
/// instantiates the shared `GenericResourceStore` with its own per-entry
/// delivery state and binds it here; controllers never learn that type.
const GraphicsRetention = @This();

context: *anyopaque,
apply_fn: *const fn (*anyopaque, CommandType) anyerror!void,
clear_pane_fn: *const fn (*anyopaque, PaneIdType) void,
set_pane_visible_fn: *const fn (*anyopaque, PaneIdType, bool) anyerror!void,
pane_visible_fn: *const fn (*anyopaque, PaneIdType) bool,
has_pane_graphics_fn: *const fn (*anyopaque, PaneIdType) bool,
ingress_version_fn: *const fn (*anyopaque) u64,
peek_credit_fn: *const fn (*anyopaque) ?CreditType,
consume_credit_fn: *const fn (*anyopaque, CreditType) void,

/// Applies one decoded graphics message. Example: `try client.graphics.apply(command);`.
pub fn apply(port: GraphicsRetention, command: CommandType) !void {
    return port.apply_fn(port.context, command);
}

/// Example: `client.graphics.clearPane(pane_id);`.
pub fn clearPane(port: GraphicsRetention, pane_id: PaneIdType) void {
    port.clear_pane_fn(port.context, pane_id);
}

/// Example: `try client.graphics.setPaneVisible(pane_id, false);`.
pub fn setPaneVisible(port: GraphicsRetention, pane_id: PaneIdType, visible: bool) !void {
    return port.set_pane_visible_fn(port.context, pane_id, visible);
}

pub fn paneVisible(port: GraphicsRetention, pane_id: PaneIdType) bool {
    return port.pane_visible_fn(port.context, pane_id);
}

pub fn hasPaneGraphics(port: GraphicsRetention, pane_id: PaneIdType) bool {
    return port.has_pane_graphics_fn(port.context, pane_id);
}

/// Advances whenever retained graphics change. Example: `const before = client.graphics.ingressVersion();`.
pub fn ingressVersion(port: GraphicsRetention) u64 {
    return port.ingress_version_fn(port.context);
}

/// Example: `while (client.graphics.peekCredit()) |credit| { ... client.graphics.consumeCredit(credit); }`.
pub fn peekCredit(port: GraphicsRetention) ?CreditType {
    return port.peek_credit_fn(port.context);
}

pub fn consumeCredit(port: GraphicsRetention, credit: CreditType) void {
    port.consume_credit_fn(port.context, credit);
}
