//! Request-scoped controller for captured-output reads, answered
//! asynchronously by the history worker.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const QueryOrigin = history_mod.model.QueryOrigin;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = @import("HistoryOutputController.zig");
