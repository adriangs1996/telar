//! The machines one account saved, as `machines.json` holds them: at most
//! `capacity` profiles with unique ids, labels and destinations, and an optional label for
//! the local machine. The CLI edits it and every window follows it, so the
//! file format is plain JSON with strict bounds and no unknown fields.
const std = @import("std");
const MachineId = @import("MachineId.zig").MachineId;
const MachineProfile = @import("MachineProfile.zig");
const AgentLogin = @import("AgentLogin.zig").AgentLogin;
const MachineProfiles = @This();

/// Profiles one file holds.
pub const capacity = 16;
/// The largest `machines.json` read or written, in bytes. Sixteen profiles
/// with every field at its longest, a destination of quotes escaped to
/// twice its length and every login take 16,381 bytes; twice that leaves a
/// new field room, and the test below fails when one no longer fits. A
/// version 1 file, all an earlier build reads, stays far under its 16 KiB.
pub const max_file_bytes = 32 * 1024;

/// The file formats this build reads. Version 2 added `telar_path` and
/// `logins`, which a telar that reads only version 1 refuses as unknown
/// fields; the version says why instead. A file whose profiles use neither
/// is still written as version 1, so a person who never ran `machine setup`
/// keeps a file every earlier build reads.
const format_version = 2;
const plain_format_version = 1;

// SAFETY: add copies the complete profile before increasing count; readers use only the occupied prefix.
rows: [capacity]MachineProfile = undefined,
count: u8 = 0,
// SAFETY: The local-label setter copies the validated text before returning; localLabel reads only local_label_len bytes.
local_label_bytes: [MachineProfile.max_label_bytes]u8 = undefined,
local_label_len: u8 = 0,

/// Parses and validates one `machines.json`.
///
/// ```zig
/// const profiles = try MachineProfiles.parse(gpa, bytes);
/// ```
pub fn parse(gpa: std.mem.Allocator, source: []const u8) !MachineProfiles {
    const WireLogins = struct {
        claude: ?AgentLogin = null,
        codex: ?AgentLogin = null,
        pi: ?AgentLogin = null,
        cursor: ?AgentLogin = null,
        opencode: ?AgentLogin = null,
    };
    const WireProfile = struct {
        id: []const u8,
        label: []const u8,
        destination: []const u8,
        color: ?[]const u8 = null,
        enabled: bool = true,
        telar_path: ?[]const u8 = null,
        logins: ?WireLogins = null,
    };
    const WireFile = struct {
        version: u16,
        local_label: ?[]const u8 = null,
        machines: []const WireProfile,
    };

    const parsed = std.json.parseFromSlice(WireFile, gpa, source, .{
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMachineProfiles,
    };
    defer parsed.deinit();

    if (parsed.value.version < plain_format_version or parsed.value.version > format_version) {
        return error.IncompatibleMachineProfiles;
    }

    if (parsed.value.machines.len > capacity) {
        return error.TooManyMachines;
    }

    var profiles: MachineProfiles = .{};
    if (parsed.value.local_label) |text| {
        try profiles.relabelLocal(text);
    }

    for (parsed.value.machines) |wire| {
        var profile = try MachineProfile.init(try MachineId.parse(wire.id), .{
            .label = wire.label,
            .destination = wire.destination,
            .color = wire.color,
            .enabled = wire.enabled,
            .telar_path = wire.telar_path,
        });
        if (wire.logins) |logins| {
            inline for (@typeInfo(WireLogins).@"struct".fields) |field| {
                profile.logins.set(@field(MachineProfile.LoginAgent, field.name), @field(logins, field.name));
            }
        }

        try profiles.add(profile);
    }

    return profiles;
}

/// Writes the profiles as the JSON `parse` reads back.
///
/// ```zig
/// try profiles.writeJson(&writer);
/// ```
pub fn writeJson(self: *const MachineProfiles, writer: *std.Io.Writer) !void {
    try writer.print("{{\"version\":{d}", .{self.version()});
    if (self.localLabel()) |text| {
        try writer.print(",\"local_label\":\"{s}\"", .{text});
    }

    try writer.writeAll(",\"machines\":[");
    for (self.slice(), 0..) |*profile, index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try writer.writeAll("\n  ");
        try writeProfileJson(writer, profile);
    }

    if (self.count != 0) {
        try writer.writeByte('\n');
    }

    try writer.writeAll("]}\n");
}

/// Writes one profile as the object `machines.json` stores it in.
///
/// ```zig
/// try MachineProfiles.writeProfileJson(&writer, &profiles.rows[0]);
/// ```
pub fn writeProfileJson(writer: *std.Io.Writer, profile: *const MachineProfile) !void {
    var id_buffer: [MachineId.text_bytes]u8 = undefined;
    try writer.print("{{\"id\":\"{s}\",\"label\":\"{s}\",\"destination\":", .{
        profile.id.format(&id_buffer),
        profile.label(),
    });
    try std.json.Stringify.encodeJsonString(profile.destination(), .{}, writer);

    if (profile.color()) |text| {
        try writer.print(",\"color\":\"{s}\"", .{text});
    }

    try writer.print(",\"enabled\":{}", .{profile.enabled});
    if (profile.telarPath()) |path| {
        try writer.print(",\"telar_path\":\"{s}\"", .{path});
    }

    var first_login = true;
    for (std.enums.values(MachineProfile.LoginAgent)) |agent| {
        const login = profile.logins.get(agent) orelse continue;
        try writer.writeAll(if (first_login) ",\"logins\":{" else ",");
        first_login = false;
        try writer.print("\"{s}\":\"{s}\"", .{ @tagName(agent), @tagName(login) });
    }

    if (!first_login) {
        try writer.writeByte('}');
    }

    try writer.writeByte('}');
}

// The oldest format that holds every field these profiles use.
fn version(self: *const MachineProfiles) u16 {
    for (self.slice()) |*profile| {
        if (profile.telarPath() != null) {
            return format_version;
        }

        for (std.enums.values(MachineProfile.LoginAgent)) |agent| {
            if (profile.logins.get(agent) != null) {
                return format_version;
            }
        }
    }

    return plain_format_version;
}

pub fn slice(self: *const MachineProfiles) []const MachineProfile {
    return self.rows[0..self.count];
}

/// The label the local machine goes by when the file sets one.
pub fn localLabel(self: *const MachineProfiles) ?[]const u8 {
    if (self.local_label_len == 0) {
        return null;
    }

    return self.local_label_bytes[0..self.local_label_len];
}

/// The row of the profile with `label`, if any.
///
/// ```zig
/// const row = profiles.find("box") orelse return error.UnknownMachine;
/// ```
pub fn find(self: *const MachineProfiles, label: []const u8) ?usize {
    for (self.slice(), 0..) |*profile, row| {
        if (std.mem.eql(u8, profile.label(), label)) {
            return row;
        }
    }

    return null;
}

/// The row of the profile for `destination`, if any.
///
/// ```zig
/// const row = profiles.findDestination("dev@box") orelse return null;
/// ```
pub fn findDestination(self: *const MachineProfiles, destination: []const u8) ?usize {
    for (self.slice(), 0..) |*profile, row| {
        if (std.mem.eql(u8, profile.destination(), destination)) {
            return row;
        }
    }

    return null;
}

/// Adds one profile whose id, label and destination no other profile uses.
/// One destination is one runtime, so a second profile for it would give a
/// window two clients with one identity on that runtime.
///
/// ```zig
/// try profiles.add(try MachineProfile.init(id, .{ .label = "box", .destination = "dev@box" }));
/// ```
pub fn add(self: *MachineProfiles, profile: MachineProfile) !void {
    if (self.count == capacity) {
        return error.TooManyMachines;
    }

    try self.requireFreeLabel(profile.label());
    for (self.slice()) |*existing| {
        if (existing.id == profile.id) {
            return error.DuplicateMachineId;
        }

        if (std.mem.eql(u8, existing.destination(), profile.destination())) {
            return error.DuplicateMachineDestination;
        }
    }

    self.rows[self.count] = profile;
    self.count += 1;
}

/// Removes the profile with `label`, keeping the others in order.
///
/// ```zig
/// try profiles.remove("box");
/// ```
pub fn remove(self: *MachineProfiles, label: []const u8) !void {
    const row = self.find(label) orelse return error.UnknownMachine;
    std.mem.copyForwards(MachineProfile, self.rows[row .. self.count - 1], self.rows[row + 1 .. self.count]);
    self.count -= 1;
}

/// Gives the profile with `label` a new label no other profile uses.
///
/// ```zig
/// try profiles.rename("box", "gpu");
/// ```
pub fn rename(self: *MachineProfiles, label: []const u8, new_label: []const u8) !void {
    const row = self.find(label) orelse return error.UnknownMachine;
    if (std.mem.eql(u8, label, new_label)) {
        return;
    }

    try self.requireFreeLabel(new_label);
    try self.rows[row].relabel(new_label);
}

/// Sets whether windows connect to the machine with `label`.
///
/// ```zig
/// try profiles.enable("box", false);
/// ```
pub fn enable(self: *MachineProfiles, label: []const u8, enabled: bool) !void {
    const row = self.find(label) orelse return error.UnknownMachine;
    self.rows[row].enabled = enabled;
}

/// Records how an agent's login on the machine with `label` stood when
/// setup last looked.
///
/// ```zig
/// try profiles.recordLogin("box", .codex, .done);
/// ```
pub fn recordLogin(self: *MachineProfiles, label: []const u8, agent: MachineProfile.LoginAgent, login: AgentLogin) !void {
    const row = self.find(label) orelse return error.UnknownMachine;
    self.rows[row].logins.set(agent, login);
}

/// Records where `telar machine setup` installed telar on the machine with
/// `label`, so commands stop depending on its PATH.
///
/// ```zig
/// try profiles.placeTelar("box", "/home/dev/.local/share/telar/0.3.0/telar");
/// ```
pub fn placeTelar(self: *MachineProfiles, label: []const u8, path: []const u8) !void {
    const row = self.find(label) orelse return error.UnknownMachine;
    try self.rows[row].placeTelar(path);
}

fn relabelLocal(self: *MachineProfiles, text: []const u8) !void {
    try MachineProfile.validateLabel(text);
    self.local_label_len = @intCast(text.len);
    @memcpy(self.local_label_bytes[0..text.len], text);
}

fn requireFreeLabel(self: *const MachineProfiles, label: []const u8) !void {
    try MachineProfile.validateLabel(label);
    if (self.find(label) != null) {
        return error.DuplicateMachineLabel;
    }

    if (self.localLabel()) |local| {
        if (std.mem.eql(u8, local, label)) {
            return error.DuplicateMachineLabel;
        }
    }
}
