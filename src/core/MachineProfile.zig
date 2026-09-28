//! One saved way to reach a machine: its identity, the label people and
//! commands use, the SSH destination, an optional color and whether windows
//! connect to it. It never holds credentials.
const std = @import("std");
const MachineId = @import("MachineId.zig").MachineId;
const ssh_destination = @import("ssh_destination.zig");
const MachineProfileFields = @import("MachineProfileFields.zig");
const remote_telar = @import("remote_telar.zig");
const AgentLogin = @import("AgentLogin.zig").AgentLogin;
const MachineProfile = @This();

/// The longest label, in bytes.
pub const max_label_bytes = 32;
/// The longest color, in bytes.
pub const max_color_bytes = 24;

id: MachineId,
label_bytes: [max_label_bytes]u8 = undefined,
label_len: u8,
destination_bytes: [ssh_destination.max_bytes]u8 = undefined,
destination_len: u8,
color_bytes: [max_color_bytes]u8 = undefined,
color_len: u8 = 0,
enabled: bool,
telar_path_bytes: [remote_telar.max_path_bytes]u8 = undefined,
telar_path_len: u8 = 0,
/// Each built-in agent's login there, as setup last saw it.
logins: std.EnumArray(LoginAgent, ?AgentLogin) = .initFill(null),

/// The agents whose logins a profile records, named as `telar integration`
/// names them.
pub const LoginAgent = enum { claude, codex, pi, cursor, opencode };

/// Validates every field and copies it into a profile.
///
/// ```zig
/// const profile = try MachineProfile.init(id, .{ .label = "box", .destination = "dev@box" });
/// ```
pub fn init(id: MachineId, fields: MachineProfileFields) !MachineProfile {
    if (id == .invalid) {
        return error.InvalidMachineId;
    }

    try validateLabel(fields.label);
    try validateDestination(fields.destination);

    var profile: MachineProfile = .{
        .id = id,
        .label_len = @intCast(fields.label.len),
        .destination_len = @intCast(fields.destination.len),
        .enabled = fields.enabled,
    };
    @memcpy(profile.label_bytes[0..fields.label.len], fields.label);
    @memcpy(profile.destination_bytes[0..fields.destination.len], fields.destination);

    if (fields.color) |color_text| {
        try validateColor(color_text);
        profile.color_len = @intCast(color_text.len);
        @memcpy(profile.color_bytes[0..color_text.len], color_text);
    }

    if (fields.telar_path) |path| {
        try profile.placeTelar(path);
    }

    return profile;
}

pub fn label(self: *const MachineProfile) []const u8 {
    return self.label_bytes[0..self.label_len];
}

pub fn destination(self: *const MachineProfile) []const u8 {
    return self.destination_bytes[0..self.destination_len];
}

pub fn color(self: *const MachineProfile) ?[]const u8 {
    if (self.color_len == 0) {
        return null;
    }

    return self.color_bytes[0..self.color_len];
}

/// Where telar was installed there, or null when commands run `telar`
/// from the PATH.
pub fn telarPath(self: *const MachineProfile) ?[]const u8 {
    if (self.telar_path_len == 0) {
        return null;
    }

    return self.telar_path_bytes[0..self.telar_path_len];
}

/// Records where telar lives there after validating the path.
///
/// ```zig
/// try profile.placeTelar("/home/dev/.local/share/telar/0.3.0/telar");
/// ```
pub fn placeTelar(self: *MachineProfile, path: []const u8) !void {
    try remote_telar.validate(path);
    self.telar_path_len = @intCast(path.len);
    @memcpy(self.telar_path_bytes[0..path.len], path);
}

/// Replaces the label after validating it; uniqueness is the store's.
///
/// ```zig
/// try profile.relabel("gpu");
/// ```
pub fn relabel(self: *MachineProfile, text: []const u8) !void {
    try validateLabel(text);
    self.label_len = @intCast(text.len);
    @memcpy(self.label_bytes[0..text.len], text);
}

/// A label is what a command line names a machine by: one to 32 ASCII
/// letters, digits, `.`, `_` or `-`, starting with a letter or a digit.
///
/// ```zig
/// try MachineProfile.validateLabel("gpu-rig");
/// ```
pub fn validateLabel(text: []const u8) !void {
    if (text.len == 0 or text.len > max_label_bytes or !std.ascii.isAlphanumeric(text[0])) {
        return error.InvalidMachineLabel;
    }

    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidMachineLabel;
        }
    }
}

/// A destination passes remote attach's validation and is valid UTF-8, so
/// `machines.json` can hold it.
///
/// ```zig
/// try MachineProfile.validateDestination("dev@box");
/// ```
pub fn validateDestination(text: []const u8) !void {
    if (text.len > ssh_destination.max_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidRemoteDestination;
    }

    try ssh_destination.validate(text);
}

/// A color is `#RRGGBB` or the name of a theme role such as `red` or
/// `accent`. The window resolves the name; an unknown one draws the default.
///
/// ```zig
/// try MachineProfile.validateColor("#e06c75");
/// ```
pub fn validateColor(text: []const u8) !void {
    if (text.len == 0 or text.len > max_color_bytes) {
        return error.InvalidMachineColor;
    }

    if (text[0] == '#') {
        if (text.len != "#RRGGBB".len) {
            return error.InvalidMachineColor;
        }

        for (text[1..]) |digit| {
            if (!std.ascii.isHex(digit)) {
                return error.InvalidMachineColor;
            }
        }

        return;
    }

    for (text) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') {
            return error.InvalidMachineColor;
        }
    }
}

test "a profile keeps what it was given" {
    const profile = try MachineProfile.init(@enumFromInt(7), .{
        .label = "box",
        .destination = "dev@box",
        .color = "#e06c75",
    });

    try std.testing.expectEqualStrings("box", profile.label());
    try std.testing.expectEqualStrings("dev@box", profile.destination());
    try std.testing.expectEqualStrings("#e06c75", profile.color().?);
    try std.testing.expect(profile.enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), profile.telarPath());
}

test "a profile keeps a valid telar path and refuses another" {
    var profile = try MachineProfile.init(@enumFromInt(7), .{
        .label = "box",
        .destination = "dev@box",
        .telar_path = "/home/dev/.local/share/telar/0.3.0/telar",
    });

    try std.testing.expectEqualStrings("/home/dev/.local/share/telar/0.3.0/telar", profile.telarPath().?);
    try std.testing.expectError(error.InvalidRemoteTelarPath, profile.placeTelar("telar"));
    try std.testing.expectEqualStrings("/home/dev/.local/share/telar/0.3.0/telar", profile.telarPath().?);
    try std.testing.expectError(error.InvalidRemoteTelarPath, MachineProfile.init(@enumFromInt(8), .{
        .label = "gpu",
        .destination = "dev@gpu",
        .telar_path = "/home/dev/$(id)",
    }));
}

test "labels, destinations and colors are validated" {
    for ([_][]const u8{ "", "-box", ".box", "box rig", "caja/1", "a" ** 33 }) |text| {
        try std.testing.expectError(error.InvalidMachineLabel, validateLabel(text));
    }

    try validateLabel("gpu-rig.lan_2");

    for ([_][]const u8{ "", "-oProxyCommand=x", "dev@box extra", "\xff@box" }) |text| {
        try std.testing.expectError(error.InvalidRemoteDestination, validateDestination(text));
    }

    for ([_][]const u8{ "", "#12345", "#12345g", "Red", "red!", "a" ** 25 }) |text| {
        try std.testing.expectError(error.InvalidMachineColor, validateColor(text));
    }

    try validateColor("accent");
    try validateColor("#A0b1C2");
}
