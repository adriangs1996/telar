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
// SAFETY: init and relabel fill label_bytes[0..label_len] before returning; label reads only that prefix.
label_bytes: [max_label_bytes]u8 = undefined,
label_len: u8,
// SAFETY: init fills destination_bytes[0..destination_len] before returning; destination reads only that prefix.
destination_bytes: [ssh_destination.max_bytes]u8 = undefined,
destination_len: u8,
// SAFETY: init copies a supplied color before returning; color_len zero means there is no color to read.
color_bytes: [max_color_bytes]u8 = undefined,
color_len: u8 = 0,
enabled: bool,
// SAFETY: placeTelar validates and copies the path before returning; telarPath reads only a nonempty recorded prefix.
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
