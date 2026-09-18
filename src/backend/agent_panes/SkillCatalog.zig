const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Catalog = @This();

value: core.AgentSkills = .{},
paths: [core.AgentSkills.capacity][1024]u8 = undefined,
path_lengths: [core.AgentSkills.capacity]u16 = @splat(0),

/// Resolves only enabled skills advertised for this pane's working directory.
/// Example: `try catalog.load(result, cwd);`
pub fn load(catalog: *Catalog, result: std.json.Value, cwd: []const u8) !void {
    catalog.value = .{ .revision = catalog.value.revision +% 1, .phase = .ready };
    const data = protocol.field(result, "data");
    if (data != .array) {
        return error.InvalidSkillCatalog;
    }
    for (data.array.items) |group| {
        if (!protocol.is(protocol.field(group, "cwd"), cwd)) {
            continue;
        }

        const skills = protocol.field(group, "skills");
        if (skills != .array) {
            return error.InvalidSkillCatalog;
        }
        const errors = protocol.field(group, "errors");
        catalog.value.truncated = errors == .array and errors.array.items.len != 0;
        for (skills.array.items) |value| {
            const enabled = protocol.field(value, "enabled");
            if (enabled != .bool or !enabled.bool) {
                continue;
            }

            const skill_path = protocol.string(protocol.field(value, "path"));
            if (!std.fs.path.isAbsolute(skill_path) or skill_path.len > 1024 or std.mem.indexOfScalar(u8, skill_path, 0) != null or !std.unicode.utf8ValidateSlice(skill_path)) {
                catalog.value.truncated = true;
                continue;
            }
            const interface = protocol.field(value, "interface");
            const short = protocol.string(protocol.field(interface, "shortDescription"));
            const legacy = protocol.string(protocol.field(value, "shortDescription"));
            const description = if (short.len > 0) short else if (legacy.len > 0) legacy else protocol.string(protocol.field(value, "description"));
            const scope = if (protocol.string(protocol.field(value, "pluginId")).len != 0) core.AgentSkill.Scope.plugin else std.meta.stringToEnum(core.AgentSkill.Scope, protocol.string(protocol.field(value, "scope"))) orelse .user;
            const index = catalog.value.count;
            catalog.value.append(.{
                .name = protocol.string(protocol.field(value, "name")),
                .label = truncate(protocol.string(protocol.field(interface, "displayName")), 128),
                .description = truncate(description, 256),
                .scope = scope,
            }) catch |err| {
                if (err != error.DuplicateSkill) {
                    catalog.value.truncated = true;
                }

                continue;
            };
            @memcpy(catalog.paths[index][0..skill_path.len], skill_path);
            catalog.path_lengths[index] = @intCast(skill_path.len);
        }

        return;
    }

    return error.InvalidSkillCatalog;
}

/// Example: `const path = catalog.path(index);`
pub fn path(catalog: *const Catalog, index: u8) []const u8 {
    return catalog.paths[index][0..catalog.path_lengths[index]];
}

fn truncate(value: []const u8, limit: usize) []const u8 {
    const line = value[0 .. std.mem.indexOfAny(u8, value, "\r\n\t") orelse value.len];
    var len = @min(line.len, limit);
    while (len > 0 and len < line.len and line[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    return line[0..len];
}
