//! Worktree tracking: registration, launches into a worktree's workspace,
//! forgetting one, and the worktree section of the workspace list.

const bytecodec = @import("bytecodec");
const std = @import("std");
const types = @import("../types.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const launch_mod = @import("launch.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const RegisterWorktree = @import("RegisterWorktree.zig");
const WorktreeRegistered = @import("WorktreeRegistered.zig");
const LaunchWorktree = @import("LaunchWorktree.zig");
const LaunchWorktreeView = @import("LaunchWorktreeView.zig");
const ForgetWorktree = @import("ForgetWorktree.zig");
const WorktreeListEntry = @import("WorktreeListEntry.zig");

/// Encodes a registration after validating every bounded field.
///
/// ```zig
/// const bytes = try encodeRegisterWorktree(&buffer, .{ .request_id = request, .source = workspace, .path = "/src/fix", .branch = "fix" });
/// ```
pub fn encodeRegisterWorktree(buffer: []u8, message: RegisterWorktree) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try validateRegistration(message);
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.register_worktree));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.source));
    try encodeOptionalPane(&encoder, message.created_by);
    try encoder.writeByte(@intFromEnum(message.origin));
    try encoder.writeSized16(message.path);
    try encoder.writeSized16(message.branch);
    try encoder.writeSized16(message.base);
    try encoder.writeSized16(message.title);
    try encoder.writeSized16(message.brief);
    return encoder.finish();
}

pub fn decodeRegisterWorktree(decoder: *Decoder) !RegisterWorktree {
    const message: RegisterWorktree = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .source = try id.workspace(try decoder.readInt(u64)),
        .created_by = try decodeOptionalPane(decoder),
        .origin = std.enums.fromInt(types.WorktreeOrigin, try decoder.readByte()) orelse
            return error.InvalidWorktreeOrigin,
        .path = try decoder.readSized16(),
        .branch = try decoder.readSized16(),
        .base = try decoder.readSized16(),
        .title = try decoder.readSized16(),
        .brief = try decoder.readSized16(),
    };
    try validateRegistration(message);
    return message;
}

pub fn encodeWorktreeRegistered(buffer: []u8, message: WorktreeRegistered) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.worktree_registered), buffer, message);
}

/// Encodes a launch into a tracked worktree.
///
/// ```zig
/// const bytes = try encodeLaunchWorktree(&buffer, .{ .request_id = request, .worktree = worktree, .size = size, .launch = launch });
/// ```
pub fn encodeLaunchWorktree(buffer: []u8, message: LaunchWorktree) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    _ = try id.worktree(id.raw(message.worktree));
    try message.size.validate();
    try codec.validateTabLabel(message.label, true);
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.launch_worktree));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.worktree));
    try encoder.writeSized16(message.label);
    try codec.encodeSize(&encoder, message.size);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeLaunchWorktree(decoder: *Decoder) !LaunchWorktreeView {
    const request_id = try id.request(try decoder.readInt(u64));
    const worktree = try id.worktree(try decoder.readInt(u64));
    const label = try decoder.readSized16();
    try codec.validateTabLabel(label, true);
    const size = try codec.decodeSize(decoder);
    return .{
        .request_id = request_id,
        .worktree = worktree,
        .label = label,
        .size = size,
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeForgetWorktree(buffer: []u8, message: ForgetWorktree) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.forget_worktree), buffer, message);
}

/// Appends one worktree entry of the workspace list.
///
/// ```zig
/// try encodeWorktreeListEntry(&encoder, entry);
/// ```
pub fn encodeWorktreeListEntry(encoder: *Encoder, entry: WorktreeListEntry) !void {
    try validateListEntry(entry);
    try encoder.writeInt(u64, id.raw(entry.worktree));
    try encoder.writeInt(u64, id.raw(entry.source));
    try encodeOptionalWorkspace(encoder, entry.workspace);
    try encodeOptionalPane(encoder, entry.created_by);
    try encoder.writeByte(@intFromEnum(entry.origin));
    try encoder.writeByte(@intFromEnum(entry.state));
    try encoder.writeSized16(entry.path);
    try encoder.writeSized16(entry.branch);
    try encoder.writeSized16(entry.base);
    try encoder.writeSized16(entry.title);
    try encoder.writeSized16(entry.brief);
    try encoder.writeInt(u32, entry.diff_added);
    try encoder.writeInt(u32, entry.diff_removed);
    try encoder.writeInt(u32, entry.diff_files);
    try encoder.writeInt(u32, entry.commits_ahead);
    try encoder.writeSized16(entry.command_label);
    try encoder.writeByte(@intFromEnum(entry.command_state));
    try encoder.writeInt(i32, entry.command_exit);
}

pub fn decodeWorktreeListEntry(decoder: *Decoder) !WorktreeListEntry {
    const entry: WorktreeListEntry = .{
        .worktree = try id.worktree(try decoder.readInt(u64)),
        .source = try id.workspace(try decoder.readInt(u64)),
        .workspace = try decodeOptionalWorkspace(decoder),
        .created_by = try decodeOptionalPane(decoder),
        .origin = std.enums.fromInt(types.WorktreeOrigin, try decoder.readByte()) orelse
            return error.InvalidWorktreeOrigin,
        .state = std.enums.fromInt(types.WorktreeState, try decoder.readByte()) orelse
            return error.InvalidWorktreeState,
        .path = try decoder.readSized16(),
        .branch = try decoder.readSized16(),
        .base = try decoder.readSized16(),
        .title = try decoder.readSized16(),
        .brief = try decoder.readSized16(),
        .diff_added = try decoder.readInt(u32),
        .diff_removed = try decoder.readInt(u32),
        .diff_files = try decoder.readInt(u32),
        .commits_ahead = try decoder.readInt(u32),
        .command_label = try decoder.readSized16(),
        .command_state = std.enums.fromInt(types.CommandState, try decoder.readByte()) orelse
            return error.InvalidCommandState,
        .command_exit = try decoder.readInt(i32),
    };
    try validateListEntry(entry);
    return entry;
}

fn validateRegistration(message: RegisterWorktree) !void {
    if (message.source == .invalid) {
        return error.InvalidWorkspaceId;
    }

    try validateWorktreeText(.{
        .path = message.path,
        .branch = message.branch,
        .base = message.base,
        .title = message.title,
        .brief = message.brief,
    });
}

fn validateListEntry(entry: WorktreeListEntry) !void {
    if (entry.source == .invalid) {
        return error.InvalidWorkspaceId;
    }

    try validateWorktreeText(.{
        .path = entry.path,
        .branch = entry.branch,
        .base = entry.base,
        .title = entry.title,
        .brief = entry.brief,
    });
    try codec.validateDisplayText(entry.command_label, types.max_worktree_command_label_bytes, true);
}

const WorktreeText = struct {
    path: []const u8,
    branch: []const u8,
    base: []const u8,
    title: []const u8,
    brief: []const u8,
};

fn validateWorktreeText(text: WorktreeText) !void {
    try codec.validateBytes(text.path, types.max_cwd_bytes, false);
    if (!std.fs.path.isAbsolutePosix(text.path)) {
        return error.InvalidWorktreePath;
    }

    try codec.validateDisplayText(text.branch, types.max_git_branch_bytes, false);
    try codec.validateDisplayText(text.base, types.max_git_branch_bytes, true);
    try codec.validateDisplayText(text.title, types.max_worktree_title_bytes, true);
    try codec.validateMessageText(text.brief, types.max_worktree_brief_bytes);
}

fn encodeOptionalPane(encoder: *Encoder, pane: ?id.PaneId) !void {
    try encoder.writeByte(@intFromBool(pane != null));
    if (pane) |value| {
        try codec.validatePaneId(value);
        try encoder.writeInt(u64, id.raw(value));
    }
}

fn decodeOptionalPane(decoder: *Decoder) !?id.PaneId {
    if (!try decoder.readBool()) {
        return null;
    }

    return try id.pane(try decoder.readInt(u64));
}

fn encodeOptionalWorkspace(encoder: *Encoder, workspace: ?id.WorkspaceId) !void {
    try encoder.writeByte(@intFromBool(workspace != null));
    if (workspace) |value| {
        _ = try id.workspace(id.raw(value));
        try encoder.writeInt(u64, id.raw(value));
    }
}

fn decodeOptionalWorkspace(decoder: *Decoder) !?id.WorkspaceId {
    if (!try decoder.readBool()) {
        return null;
    }

    return try id.workspace(try decoder.readInt(u64));
}
