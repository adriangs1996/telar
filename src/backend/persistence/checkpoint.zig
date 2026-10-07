//! Durable session checkpoint records and their file encoding.
//!
//! The record types are deliberately separate from live aggregates and from
//! client projections. A checkpoint holds only what a restart can
//! rebuild: identities, paths, labels, pane launch commands and client layout
//! replicas. File descriptors, PTYs and in-flight work are never written.

const core = @import("telar-core");
const WorkspaceRecord = @import("WorkspaceRecord.zig");
const TabRecord = @import("TabRecord.zig");
const PaneRecord = @import("PaneRecord.zig");
const LayoutRecord = @import("LayoutRecord.zig");
const WorktreeRecord = @import("WorktreeRecord.zig");
const std = @import("std");

pub const magic: *const [8]u8 = "TELARCKP";
/// Version 2 added pane titles; version 3 permits automatic tab labels.
/// Version 4 added pane kinds for agent panes; version 5 drops them again.
/// Version 6 adds worktree records; version 7 adds the machine that
/// dispatched each worktree; version 8 records whether an agent kept its
/// session in the pane; version 9 sizes a pane's launch arguments in 32 bits,
/// so a launch of up to `max_launch_bytes` fits.
/// Older labels remain explicit because their naming intent was not recorded.
pub const version: u16 = 10;
/// Version 10 adds the globally qualified coordinator attribution.
pub const coordinator_version: u16 = 10;
pub const oldest_readable_version: u16 = 1;
/// The first version whose worktree records end with `dispatched_from`.
pub const dispatched_from_version: u16 = 7;
/// The first version whose pane records end with `agent_in_pane`.
pub const agent_in_pane_version: u16 = 8;
/// The first version whose pane launch arguments carry a 32-bit length.
pub const wide_arguments_version: u16 = 9;
pub const max_file_bytes = 4 * 1024 * 1024;
/// A pane's launch command: whatever a launch request may carry, so every
/// pane that did not replace its environment is restorable.
pub const max_launch_arguments = core.max_argument_count;
pub const max_launch_bytes = core.max_argument_bytes;

pub const Record = union(enum) {
    workspace: WorkspaceRecord,
    tab: TabRecord,
    pane: PaneRecord,
    layout: LayoutRecord,
    worktree: WorktreeRecord,
};

/// The only version whose pane records end with a kind byte. Its agent
/// panes are skipped on restore.
pub const pane_kind_version: u16 = 4;

pub const LegacyPaneKind = enum(u8) {
    terminal = 0,
    agent = 1,
};

pub const Kind = enum(u8) {
    end = 0,
    workspace = 1,
    tab = 2,
    pane = 3,
    layout = 4,
    worktree = 5,
};

/// An empty title carries no source. A present one must be printable and
/// come from a durable source, so restore never revives a placeholder.
pub fn validateTitle(title: []const u8, source: u8) !void {
    if (title.len == 0) {
        if (source != 0) {
            return error.InvalidCheckpoint;
        }

        return;
    }

    core.validateSessionTitle(title) catch return error.InvalidCheckpoint;
    switch (std.enums.fromInt(core.AgentTitleSource, source) orelse return error.InvalidCheckpoint) {
        .generated, .manual, .agent => {},
        .telar, .terminal => return error.InvalidCheckpoint,
    }
}

/// A worktree record carries an absolute path and text every client can
/// decode, by the same rule the wire and the runtime's table apply.
pub fn validateWorktree(record: WorktreeRecord) !void {
    if (record.coordinator) |coordinator| {
        try coordinator.validate();
    }

    try validatePath(record.path);
    if (record.id == 0 or record.source_workspace_id == 0 or record.branch.len == 0) {
        return error.InvalidCheckpoint;
    }

    if (std.enums.fromInt(core.WorktreeOrigin, record.origin) == null) {
        return error.InvalidCheckpoint;
    }

    core.validateWorktreeText(.{
        .path = record.path,
        .branch = record.branch,
        .base = record.base,
        .title = record.title,
        .brief = record.brief,
        .dispatched_from = record.dispatched_from,
    }) catch return error.InvalidCheckpoint;
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > core.max_cwd_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidCheckpoint;
    }
}
