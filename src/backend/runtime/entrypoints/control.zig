//! Runtime-control entrypoints not yet migrated to request controllers.

const common = @import("common.zig");

pub const Actions = struct {
    context: *anyopaque,
    request_stop: *const fn (*anyopaque, common.ClientKey) void,
};

pub fn runtimeStop(client: common.ClientKey, actions: Actions) void {
    actions.request_stop(actions.context, client);
}
