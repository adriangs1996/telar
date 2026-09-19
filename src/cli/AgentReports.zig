const std = @import("std");
const Session = @import("Session.zig");
const AgentOptions = @import("arguments/AgentOptions.zig");
const ExecutionContext = @import("ExecutionContext.zig");
const Snapshot = @import("Snapshot.zig");
const PaneRef = @import("PaneRef.zig");
const control = @import("control.zig");
const AgentReports = @This();

session: *Session,
options: AgentOptions,
output: ExecutionContext,

/// Reports even before a current pane has an observed agent. Example: `try reports.run();`
pub fn run(self: *AgentReports) !void {
    const pane = try self.resolve();
    switch (self.options.action) {
        .report_state => try self.session.reportAgent(pane, self.options.report.?),
        .report_title => try self.session.reportAgentTitle(pane, std.mem.span(self.options.text.?)),
        else => return error.InvalidAgentReport,
    }

    if (self.options.json) {
        try std.json.Stringify.value(.{ .pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .accepted = true }, .{}, self.output.writer);
        try self.output.writer.writeByte('\n');
    }
}

fn resolve(self: *AgentReports) !PaneRef {
    if (self.options.target.? == .current) {
        return .{ .pane_id = try control.currentPaneId(self.output.environ), .pane_generation = try control.currentPaneGeneration(self.output.environ) };
    }

    var snapshot: Snapshot = .{};
    try self.session.fetchAgents(&snapshot);
    const target = try snapshot.resolve(self.options.target.?, self.output.environ) orelse return error.AgentNotFound;
    return .{ .pane_id = target.pane_id, .pane_generation = target.pane_generation };
}
