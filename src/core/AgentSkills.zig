const bytecodec = @import("bytecodec");
const std = @import("std");
const Skill = @import("AgentSkill.zig");
const AgentSkillInfo = @import("AgentSkillInfo.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const Skills = @This();

pub const capacity = 128;
pub const Phase = enum(u8) { loading, ready, failed };
revision: u64 = 0,
phase: Phase = .loading,
truncated: bool = false,
entries: [capacity]Skill = @splat(.{}),
count: u8 = 0,
text: [16 * 1024]u8 = @splat(0),
text_len: u16 = 0,

/// Owns the advertised metadata; provider paths remain in the runtime.
/// Example: `try skills.append(.{ .name = "review", .description = "Review changes" });`
pub fn append(self: *Skills, info: AgentSkillInfo) !void {
    if (info.name.len == 0 or info.name.len > 128 or !validText(info.name)) {
        return error.InvalidSkill;
    }
    for (info.name) |byte| {
        if (!nameByte(byte)) {
            return error.InvalidSkill;
        }
    }
    if (self.find(info.name) != null) {
        return error.DuplicateSkill;
    }

    const label = if (info.label.len == 0) info.name else info.label;
    if (label.len > 128 or info.description.len > 256 or !validText(label) or !validText(info.description)) {
        return error.InvalidSkill;
    }
    if (self.count == capacity or info.name.len + label.len + info.description.len > self.text.len - self.text_len) {
        return error.TooManySkills;
    }

    var entry: Skill = .{ .scope = info.scope };
    inline for (.{ "name", "label", "description" }, .{ info.name, label, info.description }) |field, bytes| {
        @field(entry, field ++ "_offset") = self.text_len;
        @field(entry, field ++ "_len") = @intCast(bytes.len);
        @memcpy(self.text[self.text_len..][0..bytes.len], bytes);
        self.text_len += @intCast(bytes.len);
    }

    self.entries[self.count] = entry;
    self.count += 1;
}

/// Example: `const index = skills.find("review") orelse return;`
pub fn find(self: *const Skills, name: []const u8) ?u8 {
    for (self.entries[0..self.count], 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name(self), name)) {
            return @intCast(index);
        }
    }

    return null;
}

/// Exact token boundaries prevent `$review-extra` from invoking `$review`.
/// Example: `if (skills.mentioned(prompt, index)) appendSkillInput();`
pub fn mentioned(self: *const Skills, text: []const u8, index: u8) bool {
    const name = self.entries[index].name(self);
    for (text, 0..) |byte, offset| {
        if (byte != '$' or offset > 0 and !std.ascii.isWhitespace(text[offset - 1])) {
            continue;
        }

        const rest = text[offset + 1 ..];
        if (std.mem.startsWith(u8, rest, name) and (rest.len == name.len or !nameByte(rest[name.len]))) {
            return true;
        }
    }

    return false;
}

/// Example: `if (AgentSkills.nameByte(byte)) extendToken();`
pub fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.';
}

/// Example: `try skills.encode(encoder);`
pub fn encode(self: *const Skills, encoder: *Encoder) !void {
    if (self.count > capacity or self.text_len > self.text.len) {
        return error.InvalidSkill;
    }

    try encoder.writeInt(u64, self.revision);
    try encoder.writeByte(@intFromEnum(self.phase));
    try encoder.writeByte(@intFromBool(self.truncated));
    try encoder.writeByte(self.count);
    for (self.entries[0..self.count]) |entry| {
        inline for (.{ "name", "label", "description" }) |field| {
            const offset = @field(entry, field ++ "_offset");
            const len = @field(entry, field ++ "_len");
            if (@as(usize, offset) + len > self.text_len) {
                return error.InvalidSkill;
            }

            try encoder.writeSized16(self.text[offset..][0..len]);
        }

        try encoder.writeByte(@intFromEnum(entry.scope));
    }
}

/// Example: `const skills = try AgentSkills.decode(decoder);`
pub fn decode(decoder: *Decoder) !Skills {
    var skills: Skills = .{ .revision = try decoder.readInt(u64), .phase = std.enums.fromInt(Phase, try decoder.readByte()) orelse return error.InvalidSkill, .truncated = try decoder.readBool() };
    const count = try decoder.readByte();
    if (count > capacity) {
        return error.TooManySkills;
    }
    for (0..count) |_| {
        const name = try decoder.readSized16();
        const label = try decoder.readSized16();
        const description = try decoder.readSized16();
        const scope = std.enums.fromInt(Skill.Scope, try decoder.readByte()) orelse return error.InvalidSkill;
        try skills.append(.{ .name = name, .label = label, .description = description, .scope = scope });
    }

    return skills;
}

fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return false;
    }
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

test "skills own bounded metadata and match exact explicit references" {
    var skills: Skills = .{ .phase = .ready, .revision = 7 };
    try skills.append(.{ .name = "review", .label = "Code Review", .description = "Inspect changes", .scope = .repo });
    try skills.append(.{ .name = "plugin:build", .scope = .plugin });
    try std.testing.expect(skills.mentioned("Use $review now", 0));
    try std.testing.expect(skills.mentioned("$review", 0));
    try std.testing.expect(!skills.mentioned("$review-more", 0));
    try std.testing.expect(!skills.mentioned("escaped \\$review", 0));
    try std.testing.expect(skills.mentioned("Use $plugin:build", 1));
    try std.testing.expectError(error.DuplicateSkill, skills.append(.{ .name = "review" }));
    try std.testing.expectError(error.InvalidSkill, skills.append(.{ .name = "bad name" }));
    var buffer: [1024]u8 = undefined;
    var encoder: Encoder = .init(&buffer);
    try skills.encode(&encoder);
    var decoder: Decoder = .init(buffer[0..encoder.index]);
    const copy = try Skills.decode(&decoder);
    @memset(&buffer, 0);
    try std.testing.expectEqualStrings("Code Review", copy.entries[0].label(&copy));
    try std.testing.expectEqualStrings("Inspect changes", copy.entries[0].description(&copy));
    try std.testing.expectEqual(@as(u64, 7), copy.revision);
    var tiny: Decoder = .init(&.{0});
    try std.testing.expectError(error.Truncated, Skills.decode(&tiny));
}
