const RecoveryEffects = @This();
const client_requests = @import("../../connection/root.zig").requests;
const source_namespace = @import("request_failure.zig");
const InitialOpenFailure = @import("InitialOpenFailure.zig");
context: *anyopaque,
split: *const fn (*anyopaque, client_requests.Split) anyerror!source_namespace.SplitRecovery,
attachment: *const fn (*anyopaque, client_requests.PaneOperation) anyerror!void,
close_tab: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
initial_open: *const fn (*anyopaque, InitialOpenFailure) anyerror!source_namespace.InitialOpenRecovery,
