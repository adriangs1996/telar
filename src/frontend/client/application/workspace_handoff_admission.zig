//! Application admission policy for starting one workspace handoff.

const std = @import("std");
const client_model = @import("../model.zig");

pub const Authority = enum {
    requested_departure,
    canonical_follow,
};

pub const Gate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const AdmitWorkspaceHandoffHandler = struct {
    model: *const client_model.Model,
    gate: Gate,

    /// Admits a requested departure only while idle, or a canonical follow
    /// only after the current projection has already disappeared.
    ///
    /// ```zig
    /// try handler.execute(.requested_departure);
    /// ```
    pub fn execute(handler: *const AdmitWorkspaceHandoffHandler, authority: Authority) !void {
        switch (authority) {
            .requested_departure => {
                if (handler.gate.pending(handler.gate.context)) {
                    return error.WorkspaceSwitchWhileRequestPending;
                }
            },
            .canonical_follow => {
                if (handler.model.workspaceLocation() != null) {
                    return error.WorkspaceStillActive;
                }
            },
        }
    }
};

const GateCapture = struct {
    blocked: bool = false,
    calls: usize = 0,

    fn gate(capture: *GateCapture) Gate {
        return .{ .context = capture, .pending = pending };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *GateCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;

        return capture.blocked;
    }
};

test "requested workspace departure requires an idle request lifecycle" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: GateCapture = .{ .blocked = true };
    const handler: AdmitWorkspaceHandoffHandler = .{
        .model = &model,
        .gate = capture.gate(),
    };

    try std.testing.expectError(
        error.WorkspaceSwitchWhileRequestPending,
        handler.execute(.requested_departure),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.blocked = false;
    try handler.execute(.requested_departure);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "canonical workspace follow ignores stale requests only from an empty projection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: GateCapture = .{ .blocked = true };
    const handler: AdmitWorkspaceHandoffHandler = .{
        .model = &model,
        .gate = capture.gate(),
    };

    try handler.execute(.canonical_follow);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    try model.workspace.bootstrap(@enumFromInt(1), .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    }, .{ .cols = 20, .rows = 5 });

    try std.testing.expectError(
        error.WorkspaceStillActive,
        handler.execute(.canonical_follow),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
