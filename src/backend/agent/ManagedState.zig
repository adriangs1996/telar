const std = @import("std");
const core = @import("telar-core");
const EventLine = @import("EventLine.zig");

status: core.AgentStatus,
observed_at_ms: i64,
event: EventLine = .{},

/// Projects the current root turn into the existing sidebar lifecycle report.
/// Example: `const state = ManagedState.fromSnapshot(snapshot, now_ms);`
pub fn fromSnapshot(snapshot: *const core.AgentThreadSnapshot, now_ms: i64) @This() {
    return .{
        .status = switch (snapshot.status) {
            .starting, .working => .working,
            .ready => .ready,
            .blocked => .blocked,
            .failed => .failed,
        },
        .observed_at_ms = now_ms,
        .event = activity(snapshot),
    };
}

fn activity(snapshot: *const core.AgentThreadSnapshot) EventLine {
    switch (snapshot.status) {
        .starting => return EventLine.init("Connecting"),
        .working => {},
        else => return .{},
    }

    var index = snapshot.items().len;
    while (index > 0 and snapshot.currentTurnId().len != 0) {
        index -= 1;
        const item = &snapshot.items()[index];
        if (item.role == .user or item.role == .system or item.parent_identity != 0 or item.kind == .subagent or !std.mem.eql(u8, item.sourceTurn(snapshot), snapshot.currentTurnId())) {
            continue;
        }

        const content = if (item.role == .assistant) item.text(snapshot) else item.detail(snapshot);
        const line = EventLine.init(std.mem.trimStart(u8, content, " \t\r\n"));
        if (line.len != 0) {
            return line;
        }

        const title = EventLine.init(item.title(snapshot));
        if (title.len != 0) {
            return title;
        }

        return EventLine.init(if (item.kind == .reasoning) "Thinking" else if (item.role == .assistant) "Writing response" else "Working");
    }

    return EventLine.init("Working");
}
