//! Request-scoped controller for history deletion and pruning. Both are
//! answered asynchronously by the history worker with the removed count.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const QueryOrigin = history_mod.model.QueryOrigin;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("PruneHistoryController.zig");
