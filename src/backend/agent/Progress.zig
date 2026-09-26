const core = @import("telar-core");
const std = @import("std");
const PlanChange = @import("PlanChange.zig");
/// How far an agent got, as its hooks report it: the tasks of its plan and
/// its last final answer. Task positions are identities: Claude Code numbers
/// tasks from one in creation order within a session.
const Progress = @This();

pub const max_tasks = 32;

task_subject: [max_tasks][core.max_agent_plan_step_bytes]u8 = undefined,
task_subject_len: [max_tasks]u8 = @splat(0),
task_status: [max_tasks]core.AgentPlanStatus = @splat(.pending),
task_count: u8 = 0,
/// A whole-plan report (`set`) replaces the task list with these counts.
reported_done: u16 = 0,
reported_total: u16 = 0,
reported_step: [core.max_agent_plan_step_bytes]u8 = undefined,
reported_step_len: u8 = 0,
uses_tasks: bool = false,
final_message: [core.max_agent_final_message_bytes]u8 = undefined,
final_message_len: u16 = 0,

/// Applies one plan change and returns whether the visible plan changed.
///
/// ```zig
/// _ = progress.applyPlan(.{ .op = .add, .text = "Add the reorder test" });
/// ```
pub fn applyPlan(self: *Progress, change: PlanChange) bool {
    switch (change.op) {
        .none => return false,
        .add => {
            if (self.task_count == max_tasks) {
                return false;
            }

            const slot = self.task_count;
            self.task_subject_len[slot] = @intCast(copyBounded(&self.task_subject[slot], change.text));
            self.task_status[slot] = .pending;
            self.task_count += 1;
            self.uses_tasks = true;
            return true;
        },
        .mark => {
            if (change.index >= self.task_count) {
                return false;
            }

            if (self.task_status[change.index] == change.status) {
                return false;
            }

            self.task_status[change.index] = change.status;
            return true;
        },
        .set => {
            self.uses_tasks = false;
            self.task_count = 0;
            self.reported_done = @min(change.done, change.total);
            self.reported_total = change.total;
            self.reported_step_len = @intCast(copyBounded(&self.reported_step, change.text));
            return true;
        },
    }
}

/// Replaces the final answer. Returns whether it changed.
/// Example: `_ = progress.setFinalMessage("Done. Tests pass.");`.
pub fn setFinalMessage(self: *Progress, message: []const u8) bool {
    if (std.mem.eql(u8, self.finalMessage(), message)) {
        return false;
    }

    self.final_message_len = @intCast(copyBounded(&self.final_message, message));
    return true;
}

/// Clears the plan when a new session starts in the same pane.
/// Example: `progress.reset();`.
pub fn reset(self: *Progress) void {
    self.* = .{};
}

pub fn finalMessage(self: *const Progress) []const u8 {
    return self.final_message[0..self.final_message_len];
}

/// Completed tasks, deleted ones excluded.
/// Example: `const done = progress.done();`.
pub fn done(self: *const Progress) u16 {
    if (!self.uses_tasks) {
        return self.reported_done;
    }

    var count: u16 = 0;
    for (self.task_status[0..self.task_count]) |status| {
        count += @intFromBool(status == .completed);
    }

    return count;
}

/// Tasks in the plan, deleted ones excluded.
/// Example: `const total = progress.total();`.
pub fn total(self: *const Progress) u16 {
    if (!self.uses_tasks) {
        return self.reported_total;
    }

    var count: u16 = 0;
    for (self.task_status[0..self.task_count]) |status| {
        count += @intFromBool(status != .deleted);
    }

    return count;
}

/// The task in progress, else the first pending one, else empty.
/// Example: `const step = progress.step();`.
pub fn step(self: *const Progress) []const u8 {
    if (!self.uses_tasks) {
        return self.reported_step[0..self.reported_step_len];
    }

    var pending: ?usize = null;
    for (self.task_status[0..self.task_count], 0..) |status, index| {
        if (status == .in_progress) {
            return self.subjectAt(index);
        }

        if (status == .pending and pending == null) {
            pending = index;
        }
    }

    return if (pending) |index| self.subjectAt(index) else "";
}

fn subjectAt(self: *const Progress, index: usize) []const u8 {
    return self.task_subject[index][0..self.task_subject_len[index]];
}

/// Copies at most `storage.len` bytes, cut on a UTF-8 boundary.
fn copyBounded(storage: []u8, value: []const u8) usize {
    var len = @min(value.len, storage.len);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    @memcpy(storage[0..len], value[0..len]);
    return len;
}

test "tasks count by status and the step follows the task in progress" {
    var progress: Progress = .{};

    _ = progress.applyPlan(.{ .op = .add, .text = "Read Tabs.zig" });
    _ = progress.applyPlan(.{ .op = .add, .text = "Add the column" });
    _ = progress.applyPlan(.{ .op = .add, .text = "Obsolete" });
    try std.testing.expectEqualStrings("Read Tabs.zig", progress.step());

    _ = progress.applyPlan(.{ .op = .mark, .index = 0, .status = .completed });
    _ = progress.applyPlan(.{ .op = .mark, .index = 1, .status = .in_progress });
    _ = progress.applyPlan(.{ .op = .mark, .index = 2, .status = .deleted });
    try std.testing.expectEqual(@as(u16, 1), progress.done());
    try std.testing.expectEqual(@as(u16, 2), progress.total());
    try std.testing.expectEqualStrings("Add the column", progress.step());
    try std.testing.expect(!progress.applyPlan(.{ .op = .mark, .index = 9, .status = .completed }));
}

test "a whole-plan report replaces tasks and bounds its counts" {
    var progress: Progress = .{};
    _ = progress.applyPlan(.{ .op = .add, .text = "gone" });

    try std.testing.expect(progress.applyPlan(.{ .op = .set, .done = 9, .total = 4, .text = "Write tests" }));
    try std.testing.expectEqual(@as(u16, 4), progress.done());
    try std.testing.expectEqual(@as(u16, 4), progress.total());
    try std.testing.expectEqualStrings("Write tests", progress.step());
}

test "the final message is bounded and unchanged values report no change" {
    var progress: Progress = .{};
    try std.testing.expect(progress.setFinalMessage("Done.\nTests pass."));
    try std.testing.expect(!progress.setFinalMessage("Done.\nTests pass."));

    const long = "é" ** core.max_agent_final_message_bytes;
    _ = progress.setFinalMessage(long);
    try std.testing.expect(progress.finalMessage().len <= core.max_agent_final_message_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(progress.finalMessage()));
}
