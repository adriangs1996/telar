//! Protocol controller for one UI-directed pane-focus exchange.

const std = @import("std");
const core = @import("telar-core");
const panes = @import("../../../pane/root.zig");
const clients = @import("../../client/root.zig");
const telemetry = @import("../../observability/root.zig").telemetry;
pub const schema = core.schema;
pub const pane_mod = panes;
pub const ClientSession = clients.session.Session;
pub const ClientKey = clients.session.Key;

pub const Controller = @import("PaneFocusController.zig");
