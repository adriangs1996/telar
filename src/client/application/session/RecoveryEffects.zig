const SplitType = @import("../../connection/Split.zig");
const request_failure = @import("request_failure.zig");
const PaneOperationType = @import("../../connection/PaneOperation.zig");
const TabLocationType = @import("telar-core").TabLocation;
const InitialOpenFailure = @import("InitialOpenFailure.zig");
const RecoveryEffects = @This();

context: *anyopaque,
split: *const fn (*anyopaque, SplitType) anyerror!request_failure.SplitRecovery,
attachment: *const fn (*anyopaque, PaneOperationType) anyerror!void,
close_tab: *const fn (*anyopaque, TabLocationType) anyerror!void,
initial_open: *const fn (*anyopaque, InitialOpenFailure) anyerror!request_failure.InitialOpenRecovery,
