//! Bounded presentation data for the client-owned task sidebar.
//!
//! Agent detection will eventually populate this snapshot from runtime data.
//! The widget deliberately consumes this type instead of the multiplexer so
//! detection, IPC, and rendering can evolve without sharing live state.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_tasks = 64;
pub const section_count = @typeInfo(Section).@"enum".fields.len;

pub const TaskKey = struct {
    id: u64,
    generation: u32,
};

pub const Tab = enum(u2) {
    inbox,
    tasks,
    reviews,

    pub fn label(tab: Tab) []const u8 {
        return switch (tab) {
            .inbox => "inbox",
            .tasks => "tasks",
            .reviews => "reviews",
        };
    }

    pub fn shortcut(tab: Tab) u8 {
        return switch (tab) {
            .inbox => '1',
            .tasks => '2',
            .reviews => '3',
        };
    }
};

pub const Section = enum(u2) {
    needs_you,
    ready,
    running,
    background,

    pub fn label(section: Section) []const u8 {
        return switch (section) {
            .needs_you => "NEEDS YOU",
            .ready => "READY",
            .running => "RUNNING",
            .background => "BACKGROUND",
        };
    }
};

pub const TaskAction = enum(u2) {
    none,
    decide,
    debug,
    review,

    pub fn glyph(action: TaskAction) []const u8 {
        return switch (action) {
            .none => "",
            .decide, .review => "\u{25c6}",
            .debug => "\u{2717}",
        };
    }

    pub fn label(action: TaskAction) []const u8 {
        return switch (action) {
            .none => "",
            .decide => "decide",
            .debug => "debug",
            .review => "review",
        };
    }

    pub fn filled(action: TaskAction) bool {
        return action == .decide;
    }
};

pub const Origin = enum(u2) {
    agent,
    shell,
    host,
};

pub const Provider = enum(u3) {
    unknown,
    claude,
    codex,
    cursor,
    shell,
    host,
};

pub const Status = enum(u3) {
    unknown,
    waiting,
    failed,
    ready,
    working,
    queued,

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .unknown => "unknown",
            .waiting => "waiting",
            .failed => "failed",
            .ready => "ready",
            .working => "working",
            .queued => "queued",
        };
    }
};

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: u16 = 0,

        const Self = @This();

        fn init(value: []const u8) !Self {
            if (value.len > capacity) return error.SidebarTextTooLong;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSidebarText;
            var text: Self = .{ .len = @intCast(value.len) };
            @memcpy(text.bytes[0..value.len], value);
            return text;
        }

        pub fn slice(text: *const Self) []const u8 {
            return text.bytes[0..text.len];
        }
    };
}

pub const TaskInput = struct {
    key: TaskKey,
    pane_id: ?schema.PaneId = null,
    title: []const u8,
    place: []const u8 = "",
    place_detail: []const u8 = "",
    tool: []const u8 = "",
    note: []const u8 = "",
    status_detail: []const u8 = "",
    section: Section,
    action: TaskAction = .none,
    origin: Origin = .agent,
    provider: Provider = .unknown,
    status: Status = .unknown,
    inbox: bool = true,
    review: bool = false,
};

pub const Task = struct {
    key: TaskKey,
    pane_id: ?schema.PaneId,
    title: Text(96),
    place: Text(128),
    place_detail: Text(96),
    tool: Text(64),
    note: Text(192),
    status_detail: Text(64),
    section: Section,
    action: TaskAction,
    origin: Origin,
    provider: Provider,
    status: Status,
    inbox: bool,
    review: bool,

    fn init(input: TaskInput) !Task {
        if (input.title.len == 0) return error.EmptySidebarTaskTitle;
        return .{
            .key = input.key,
            .pane_id = input.pane_id,
            .title = try .init(input.title),
            .place = try .init(input.place),
            .place_detail = try .init(input.place_detail),
            .tool = try .init(input.tool),
            .note = try .init(input.note),
            .status_detail = try .init(input.status_detail),
            .section = input.section,
            .action = input.action,
            .origin = input.origin,
            .provider = input.provider,
            .status = input.status,
            .inbox = input.inbox,
            .review = input.review,
        };
    }
};

pub const SnapshotInput = struct {
    revision: u64,
    tasks: []const TaskInput,
};

/// One disposable client replica. Replacement happens outside rendering and
/// needs no allocation. Revisions and task generations reject stale identity.
pub const Snapshot = struct {
    revision: u64 = 0,
    initialized: bool = false,
    items: [max_tasks]Task = undefined,
    count: u8 = 0,

    pub fn replace(snapshot: *Snapshot, input: SnapshotInput) !bool {
        if (snapshot.initialized and input.revision <= snapshot.revision) return false;
        if (input.tasks.len > max_tasks) return error.TooManySidebarTasks;

        var replacement: Snapshot = .{
            .revision = input.revision,
            .initialized = true,
            .count = @intCast(input.tasks.len),
        };
        for (input.tasks, 0..) |task, index| {
            for (input.tasks[0..index]) |previous| {
                if (std.meta.eql(previous.key, task.key))
                    return error.DuplicateSidebarTask;
            }
            replacement.items[index] = try .init(task);
        }
        snapshot.* = replacement;
        return true;
    }

    pub fn slice(snapshot: *const Snapshot) []const Task {
        return snapshot.items[0..snapshot.count];
    }

    pub fn find(snapshot: *const Snapshot, key: TaskKey) ?*const Task {
        for (snapshot.slice()) |*task| {
            if (std.meta.eql(task.key, key)) return task;
        }
        return null;
    }

    pub fn tabCount(snapshot: *const Snapshot, tab: Tab) u16 {
        var count: u16 = 0;
        for (snapshot.slice()) |*task| count += @intFromBool(visibleInTab(task, tab));
        return count;
    }

    pub fn firstInTab(snapshot: *const Snapshot, tab: Tab) ?*const Task {
        for (snapshot.slice()) |*task| {
            if (visibleInTab(task, tab)) return task;
        }
        return null;
    }
};

pub fn visibleInTab(task: *const Task, tab: Tab) bool {
    return switch (tab) {
        .inbox => task.inbox,
        .tasks => true,
        .reviews => task.review,
    };
}

test "snapshots own bounded task text and ignore stale replacement" {
    var snapshot: Snapshot = .{};
    const input = [_]TaskInput{.{
        .key = .{ .id = 7, .generation = 2 },
        .title = "Fix auth token refresh",
        .place = "guruwalk/api",
        .section = .needs_you,
    }};
    try std.testing.expect(try snapshot.replace(.{ .revision = 4, .tasks = &input }));
    try std.testing.expectEqualStrings("Fix auth token refresh", snapshot.slice()[0].title.slice());
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .tasks = &.{} }));
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "the first runtime snapshot may use revision zero" {
    var snapshot: Snapshot = .{};
    const input = [_]TaskInput{.{
        .key = .{ .id = 1, .generation = 1 },
        .title = "first",
        .section = .ready,
    }};
    try std.testing.expect(try snapshot.replace(.{ .revision = 0, .tasks = &input }));
    try std.testing.expect(snapshot.initialized);
    try std.testing.expectEqual(@as(u8, 1), snapshot.count);
}

test "snapshot rejects duplicate stable task identities" {
    var snapshot: Snapshot = .{};
    const input = [_]TaskInput{
        .{ .key = .{ .id = 1, .generation = 1 }, .title = "one", .section = .ready },
        .{ .key = .{ .id = 1, .generation = 1 }, .title = "two", .section = .running },
    };
    try std.testing.expectError(
        error.DuplicateSidebarTask,
        snapshot.replace(.{ .revision = 1, .tasks = &input }),
    );
}
