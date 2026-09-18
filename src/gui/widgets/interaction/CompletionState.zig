const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const State = @This();

pub const Entry = union(enum) { command: core.AgentCommand.Kind, skill: u8 };
pub const visible_rows = 8;
pane_id: ?core.PaneId = null,
attachment_generation: u64 = 0,
revision: u64 = 0,
catalog_revision: u64 = 0,
generation: u64 = 0,
open: bool = false,
slash: bool = false,
start: u32 = 0,
end: u32 = 0,
query: [160]u8 = undefined,
query_len: u8 = 0,
entries: [core.AgentSkills.capacity + core.AgentCommand.kinds.len]Entry = undefined,
count: u8 = 0,
selected: u8 = 0,
first: u8 = 0,

/// Resolves only the token at the caret; a selection or whitespace closes it.
/// Example: `state.update(thread);`
pub fn update(state: *State, thread: client.ThreadView) void {
    if (!thread.focused) {
        return;
    }

    const catalog_revision = if (thread.transcript) |snapshot| snapshot.skills.revision else 0;
    const changed = state.pane_id != thread.pane_id or state.attachment_generation != thread.attachment_generation or state.revision != thread.composer_revision or state.catalog_revision != catalog_revision;
    if (!changed) {
        return;
    }

    state.pane_id = thread.pane_id;
    state.attachment_generation = thread.attachment_generation;
    state.revision = thread.composer_revision;
    state.catalog_revision = catalog_revision;
    state.generation +%= 1;
    state.open = false;
    state.selected = 0;
    state.first = 0;
    state.count = 0;
    const field = thread.composer_field orelse return;
    const text = thread.composer;
    const head = field.head;
    if (field.anchor != head or head == 0 or head > text.len) {
        return;
    }

    var start = head;
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) {
        start -= 1;
    }
    if (start == head) {
        return;
    }
    if (text[start] != '$' and (text[start] != '/' or std.mem.trim(u8, text[0..start], " \t\r\n").len != 0)) {
        return;
    }
    const query = text[start + 1 .. head];
    if (query.len > state.query.len) {
        return;
    }
    for (query) |byte| {
        if (!core.AgentSkills.nameByte(byte)) {
            return;
        }
    }

    var end = head;
    while (end < text.len and core.AgentSkills.nameByte(text[end])) {
        end += 1;
    }
    state.slash = text[start] == '/';
    state.start = @intCast(start);
    state.end = @intCast(end);
    @memcpy(state.query[0..query.len], query);
    state.query_len = @intCast(query.len);
    state.open = true;
    if (state.slash) {
        for (core.AgentCommand.kinds) |kind| {
            if (std.ascii.startsWithIgnoreCase(@tagName(kind), query)) {
                state.entries[state.count] = .{ .command = kind };
                state.count += 1;
            }
        }
    }

    const skills = if (thread.transcript) |snapshot| &snapshot.skills else return;
    for (skills.entries[0..skills.count], 0..) |skill, index| {
        const name = skill.name(skills);
        var match = query;
        if (state.slash) {
            if (std.ascii.startsWithIgnoreCase("skill:", query)) {
                match = "";
            } else if (std.ascii.startsWithIgnoreCase(query, "skill:")) {
                match = query[6..];
            } else {
                continue;
            }
        }
        if (std.ascii.indexOfIgnoreCase(name, match) != null or std.ascii.indexOfIgnoreCase(skill.label(skills), match) != null) {
            state.entries[state.count] = .{ .skill = @intCast(index) };
            state.count += 1;
        }
    }
}

/// Example: `state.dismiss();`
pub fn dismiss(state: *State) void {
    state.open = false;
}

/// Example: `state.move(true);`
pub fn move(state: *State, forward: bool) void {
    if (state.count == 0) {
        return;
    }

    state.selected = if (forward) (state.selected + 1) % state.count else if (state.selected == 0) state.count - 1 else state.selected - 1;
    if (state.selected < state.first) {
        state.first = state.selected;
    } else if (state.selected >= @as(u16, state.first) + visible_rows) {
        state.first = state.selected - visible_rows + 1;
    }
}
