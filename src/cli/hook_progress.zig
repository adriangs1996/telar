//! What a hook event says about an agent's progress: the directory it works
//! in and the linked worktree that directory resolves to, one plan change
//! from its task tools, and its final answer when a turn stops. Claude Code
//! numbers tasks from one in creation order (`TaskCreate`, then `TaskUpdate`
//! by `taskId`); `TodoWrite` and Codex's `update_plan` send the whole plan.

const std = @import("std");
const core = @import("telar-core");
const gitstatus = @import("gitstatus");
const ProgressHookInput = @import("ProgressHookInput.zig");
const ProgressStorage = @import("ProgressStorage.zig");

/// Maps one hook event to a progress report, or null for subagent events and
/// events that carry nothing to report. Request and pane fields are left for
/// the caller.
///
/// ```zig
/// var storage: ProgressStorage = .{};
/// const report = hook_progress.map(io, input, &storage) orelse return;
/// ```
pub fn map(io: std.Io, input: ProgressHookInput, storage: *ProgressStorage) ?core.ReportAgentProgress {
    if (input.agent_id) |agent_id| {
        if (agent_id.len != 0) {
            return null;
        }
    }

    var report: core.ReportAgentProgress = .{
        .request_id = .none,
        .pane_id = .invalid,
        .pane_generation = 0,
    };
    if (input.cwd.len != 0 and input.cwd.len <= core.max_cwd_bytes and std.fs.path.isAbsolute(input.cwd)) {
        report.cwd = input.cwd;
        if (gitstatus.linked_worktree.find(io, input.cwd, &storage.root, &storage.head)) |linked| {
            // A branch the runtime cannot hold whole names no worktree: a
            // cut one would never match `telar worktree` or `worktree:`.
            if (core.validateWorktreeText(.{ .path = linked.root, .branch = linked.branch })) |_| {
                report.work_tree_path = linked.root;
                report.work_tree_branch = linked.branch;
            } else |_| {}
        }
    }

    mapPlan(input, storage, &report);
    if (std.mem.eql(u8, input.event, "Stop")) {
        report.final_message = sanitizeMessage(input.last_assistant_message, &storage.message);
    }

    if (report.cwd.len == 0 and report.plan_op == .none and report.final_message.len == 0) {
        return null;
    }

    return report;
}

fn mapPlan(input: ProgressHookInput, storage: *ProgressStorage, report: *core.ReportAgentProgress) void {
    if (std.mem.eql(u8, input.event, "SessionStart")) {
        report.plan_op = .set;
        return;
    }

    if (!std.mem.eql(u8, input.event, "PostToolUse") or input.tool_input != .object) {
        return;
    }

    const fields = input.tool_input.object;
    if (std.mem.eql(u8, input.tool_name, "TaskCreate")) {
        const subject = stringField(fields, "subject") orelse return;
        report.plan_op = .add;
        report.plan_text = displayLine(subject, &storage.step);
        return;
    }

    if (std.mem.eql(u8, input.tool_name, "TaskUpdate")) {
        const id_text = stringField(fields, "taskId") orelse return;
        const id = std.fmt.parseUnsigned(u16, id_text, 10) catch return;
        const status = planStatus(stringField(fields, "status") orelse return) orelse return;
        if (id == 0) {
            return;
        }

        report.plan_op = .mark;
        report.plan_index = id - 1;
        report.plan_status = status;
        return;
    }

    if (std.mem.eql(u8, input.tool_name, "TodoWrite")) {
        const todos = arrayField(fields, "todos") orelse return;
        setPlan(todos, .{ .text = "content", .active = "activeForm" }, storage, report);
        return;
    }

    if (std.mem.eql(u8, input.tool_name, "update_plan")) {
        const plan = arrayField(fields, "plan") orelse return;
        setPlan(plan, .{ .text = "step", .active = "step" }, storage, report);
    }
}

const PlanFields = struct {
    text: []const u8,
    active: []const u8,
};

/// Counts a whole plan and names the step in progress, else the first
/// pending one.
fn setPlan(items: std.json.Array, fields: PlanFields, storage: *ProgressStorage, report: *core.ReportAgentProgress) void {
    var done: u16 = 0;
    var total: u16 = 0;
    var current: []const u8 = "";
    var pending: []const u8 = "";
    for (items.items) |item| {
        if (item != .object) {
            continue;
        }

        const status = planStatus(stringField(item.object, "status") orelse "pending") orelse .pending;
        if (status == .deleted) {
            continue;
        }

        total +|= 1;
        if (status == .completed) {
            done +|= 1;
        } else if (status == .in_progress and current.len == 0) {
            current = stringField(item.object, fields.active) orelse stringField(item.object, fields.text) orelse "";
        } else if (status == .pending and pending.len == 0) {
            pending = stringField(item.object, fields.text) orelse "";
        }
    }

    report.plan_op = .set;
    report.plan_done = done;
    report.plan_total = total;
    report.plan_text = displayLine(if (current.len != 0) current else pending, &storage.step);
}

fn planStatus(text: []const u8) ?core.AgentPlanStatus {
    return std.meta.stringToEnum(core.AgentPlanStatus, text);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .integer => null,
        else => null,
    };
}

fn arrayField(object: std.json.ObjectMap, name: []const u8) ?std.json.Array {
    const value = object.get(name) orelse return null;
    return if (value == .array) value.array else null;
}

/// The first line of `text` without control bytes, cut to the step bound on
/// a UTF-8 boundary.
fn displayLine(text: []const u8, buffer: *[core.max_agent_plan_step_bytes]u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (byte == '\n' or len == buffer.len) {
            break;
        }

        if (byte < 0x20 or byte == 0x7f) {
            continue;
        }

        buffer[len] = byte;
        len += 1;
    }

    return validPrefix(buffer[0..len]);
}

/// A final answer keeps its lines and tabs; every other control byte is
/// dropped so no escape sequence rides along, and it is cut on a UTF-8
/// boundary.
fn sanitizeMessage(text: []const u8, buffer: *[core.max_agent_final_message_bytes]u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (len == buffer.len) {
            break;
        }

        const kept = byte == '\n' or byte == '\t' or (byte >= 0x20 and byte != 0x7f);
        if (kept) {
            buffer[len] = byte;
            len += 1;
        }
    }

    return validPrefix(std.mem.trim(u8, buffer[0..len], " \n\t"));
}

fn validPrefix(text: []const u8) []const u8 {
    var len = text.len;
    while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) {
        len -= 1;
    }

    return text[0..len];
}

fn parse(json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
}

test "task tools add and mark tasks by their one-based id" {
    var storage: ProgressStorage = .{};
    const created = try parse("{\"subject\":\"Add the reorder test\",\"activeForm\":\"Adding the reorder test\"}");
    defer created.deinit();
    const add = map(std.testing.io, .{ .event = "PostToolUse", .tool_name = "TaskCreate", .tool_input = created.value }, &storage).?;
    try std.testing.expectEqual(core.AgentPlanOp.add, add.plan_op);
    try std.testing.expectEqualStrings("Add the reorder test", add.plan_text);

    const updated = try parse("{\"taskId\":\"2\",\"status\":\"in_progress\"}");
    defer updated.deinit();
    const mark = map(std.testing.io, .{ .event = "PostToolUse", .tool_name = "TaskUpdate", .tool_input = updated.value }, &storage).?;
    try std.testing.expectEqual(core.AgentPlanOp.mark, mark.plan_op);
    try std.testing.expectEqual(@as(u16, 1), mark.plan_index);
    try std.testing.expectEqual(core.AgentPlanStatus.in_progress, mark.plan_status);

    try std.testing.expect(map(std.testing.io, .{ .event = "PreToolUse", .tool_name = "TaskCreate", .tool_input = created.value }, &storage) == null);
    try std.testing.expect(map(std.testing.io, .{ .event = "PostToolUse", .agent_id = "sub", .tool_name = "TaskCreate", .tool_input = created.value }, &storage) == null);
}

test "whole-plan tools count completed steps and name the current one" {
    var storage: ProgressStorage = .{};
    const todos = try parse("{\"todos\":[{\"content\":\"Read\",\"status\":\"completed\",\"activeForm\":\"Reading\"},{\"content\":\"Write\",\"status\":\"in_progress\",\"activeForm\":\"Writing\"},{\"content\":\"Ship\",\"status\":\"pending\"}]}");
    defer todos.deinit();
    const claude = map(std.testing.io, .{ .event = "PostToolUse", .tool_name = "TodoWrite", .tool_input = todos.value }, &storage).?;
    try std.testing.expectEqual(core.AgentPlanOp.set, claude.plan_op);
    try std.testing.expectEqual(@as(u16, 1), claude.plan_done);
    try std.testing.expectEqual(@as(u16, 3), claude.plan_total);
    try std.testing.expectEqualStrings("Writing", claude.plan_text);

    const plan = try parse("{\"plan\":[{\"step\":\"Inspect\",\"status\":\"completed\"},{\"step\":\"Patch\",\"status\":\"pending\"}]}");
    defer plan.deinit();
    const codex = map(std.testing.io, .{ .event = "PostToolUse", .tool_name = "update_plan", .tool_input = plan.value }, &storage).?;
    try std.testing.expectEqual(@as(u16, 1), codex.plan_done);
    try std.testing.expectEqual(@as(u16, 2), codex.plan_total);
    try std.testing.expectEqualStrings("Patch", codex.plan_text);
}

test "a stop keeps the final answer's lines and drops escape sequences" {
    var storage: ProgressStorage = .{};
    const stop = map(std.testing.io, .{ .event = "Stop", .last_assistant_message = "Done.\n\x1b[31mTests\x1b[0m pass.\n" }, &storage).?;
    try std.testing.expectEqualStrings("Done.\n[31mTests[0m pass.", stop.final_message);
    const reset = map(std.testing.io, .{ .event = "SessionStart" }, &storage).?;
    try std.testing.expectEqual(core.AgentPlanOp.set, reset.plan_op);
    try std.testing.expectEqual(@as(u16, 0), reset.plan_total);
}
