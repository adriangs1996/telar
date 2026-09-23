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
pub fn update(self: *State, thread: client.ThreadView) void {
    if (!thread.focused) {
        return;
    }

    const catalog_revision = if (thread.transcript) |snapshot| snapshot.skills.revision else 0;
    const changed = self.pane_id != thread.pane_id or self.attachment_generation != thread.attachment_generation or self.revision != thread.composer_revision or self.catalog_revision != catalog_revision;
    if (!changed) {
        return;
    }

    self.pane_id = thread.pane_id;
    self.attachment_generation = thread.attachment_generation;
    self.revision = thread.composer_revision;
    self.catalog_revision = catalog_revision;
    self.generation +%= 1;
    self.open = false;
    self.selected = 0;
    self.first = 0;
    self.count = 0;
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
    if (query.len > self.query.len) {
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
    self.slash = text[start] == '/';
    self.start = @intCast(start);
    self.end = @intCast(end);
    @memcpy(self.query[0..query.len], query);
    self.query_len = @intCast(query.len);
    self.open = true;
    if (self.slash) {
        for (core.AgentCommand.kinds) |kind| {
            if (std.ascii.startsWithIgnoreCase(@tagName(kind), query)) {
                self.entries[self.count] = .{ .command = kind };
                self.count += 1;
            }
        }
    }

    const skills = if (thread.transcript) |snapshot| &snapshot.skills else return;
    for (skills.entries[0..skills.count], 0..) |skill, index| {
        const name = skill.name(skills);
        var match = query;
        if (self.slash) {
            if (std.ascii.startsWithIgnoreCase("skill:", query)) {
                match = "";
            } else if (std.ascii.startsWithIgnoreCase(query, "skill:")) {
                match = query[6..];
            } else {
                continue;
            }
        }
        if (std.ascii.indexOfIgnoreCase(name, match) != null or std.ascii.indexOfIgnoreCase(skill.label(skills), match) != null) {
            self.entries[self.count] = .{ .skill = @intCast(index) };
            self.count += 1;
        }
    }
}

/// Example: `state.dismiss();`
pub fn dismiss(self: *State) void {
    self.open = false;
}

/// Example: `state.move(true);`
pub fn move(self: *State, forward: bool) void {
    if (self.count == 0) {
        return;
    }

    self.selected = if (forward) (self.selected + 1) % self.count else if (self.selected == 0) self.count - 1 else self.selected - 1;
    if (self.selected < self.first) {
        self.first = self.selected;
    } else if (self.selected >= @as(u16, self.first) + visible_rows) {
        self.first = self.selected - visible_rows + 1;
    }
}
