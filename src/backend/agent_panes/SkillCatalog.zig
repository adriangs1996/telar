const jsonl = @import("jsonl");
const std = @import("std");
const core = @import("telar-core");
const Catalog = @This();

value: core.AgentSkills = .{},
paths: [core.AgentSkills.capacity][1024]u8 = undefined,
path_lengths: [core.AgentSkills.capacity]u16 = @splat(0),

/// Resolves only enabled skills advertised for this pane's working directory.
/// Example: `try catalog.load(result, cwd);`
pub fn load(self: *Catalog, result: std.json.Value, cwd: []const u8) !void {
    self.value = .{ .revision = self.value.revision +% 1, .phase = .ready };
    const data = jsonl.field(result, "data");
    if (data != .array) {
        return error.InvalidSkillCatalog;
    }
    for (data.array.items) |group| {
        if (!jsonl.is(jsonl.field(group, "cwd"), cwd)) {
            continue;
        }

        const skills = jsonl.field(group, "skills");
        if (skills != .array) {
            return error.InvalidSkillCatalog;
        }
        const errors = jsonl.field(group, "errors");
        self.value.truncated = errors == .array and errors.array.items.len != 0;
        for (skills.array.items) |value| {
            const enabled = jsonl.field(value, "enabled");
            if (enabled != .bool or !enabled.bool) {
                continue;
            }

            const skill_path = jsonl.string(jsonl.field(value, "path"));
            if (!std.fs.path.isAbsolute(skill_path) or skill_path.len > 1024 or std.mem.indexOfScalar(u8, skill_path, 0) != null or !std.unicode.utf8ValidateSlice(skill_path)) {
                self.value.truncated = true;
                continue;
            }
            const interface = jsonl.field(value, "interface");
            const short = jsonl.string(jsonl.field(interface, "shortDescription"));
            const legacy = jsonl.string(jsonl.field(value, "shortDescription"));
            const description = if (short.len > 0) short else if (legacy.len > 0) legacy else jsonl.string(jsonl.field(value, "description"));
            const scope = if (jsonl.string(jsonl.field(value, "pluginId")).len != 0) core.AgentSkill.Scope.plugin else std.meta.stringToEnum(core.AgentSkill.Scope, jsonl.string(jsonl.field(value, "scope"))) orelse .user;
            const index = self.value.count;
            self.value.append(.{
                .name = jsonl.string(jsonl.field(value, "name")),
                .label = truncate(jsonl.string(jsonl.field(interface, "displayName")), 128),
                .description = truncate(description, 256),
                .scope = scope,
            }) catch |err| {
                if (err != error.DuplicateSkill) {
                    self.value.truncated = true;
                }

                continue;
            };
            @memcpy(self.paths[index][0..skill_path.len], skill_path);
            self.path_lengths[index] = @intCast(skill_path.len);
        }

        return;
    }

    return error.InvalidSkillCatalog;
}

/// Example: `const path = catalog.path(index);`
pub fn path(self: *const Catalog, index: u8) []const u8 {
    return self.paths[index][0..self.path_lengths[index]];
}

fn truncate(value: []const u8, limit: usize) []const u8 {
    const line = value[0 .. std.mem.indexOfAny(u8, value, "\r\n\t") orelse value.len];
    var len = @min(line.len, limit);
    while (len > 0 and len < line.len and line[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    return line[0..len];
}
