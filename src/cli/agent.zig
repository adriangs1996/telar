//! The `telar agent` command family: list, inspect, wait for, prompt and read
//! the agents running in the local runtime.

const std = @import("std");
const AgentOptions = @import("arguments/AgentOptions.zig");
const Session = @import("Session.zig");
const control = @import("control.zig");
const ExecutionContext = @import("ExecutionContext.zig");
const Snapshot = @import("Snapshot.zig");
const PaneRef = @import("PaneRef.zig");
const ControlAgent = @import("ControlAgent.zig");
const Text = @import("Text.zig");
const AgentReports = @import("AgentReports.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const core = @import("telar-core");

const poll_interval_ms = 250;
const prompt_start_grace_ms = 5_000;
/// How long `prompt --interrupt` waits for the interrupted turn to stop.
const interrupt_settle_ms = 15_000;

pub const exit_ok: u8 = 0;
pub const exit_failure: u8 = 1;
pub const exit_not_found: u8 = 2;
pub const exit_timeout: u8 = 3;

/// Runs one agent command and returns the process exit code. Failures are
/// explained on stderr; data goes to stdout as rows or JSON.
///
/// ```zig
/// std.process.exit(try agent.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: AgentOptions) !u8 {
    var session = switch (options.action) {
        .list, .get, .wait, .prompt, .read, .interrupt, .report_session => try Session.open(init, options.socket),
        else => try Session.attach(init, options.socket),
    };
    defer session.close();
    var catalog: WorktreeCatalog = .init(init.gpa);
    defer catalog.deinit();
    if (options.target) |target| {
        if (target == .worktree) {
            var catalog_session = try Session.open(init, options.socket);
            defer catalog_session.close();
            try catalog_session.fetchCatalog(&catalog);
        }
    }

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(&session, options, .{ .writer = writer, .environ = init.minimal.environ, .catalog = &catalog }) catch |err| {
        std.debug.print("telar agent: {s}\n", .{control.describe(err)});
        return switch (err) {
            error.AgentNotFound, error.PaneNotFound, error.PaneExited, error.WorktreeNotFound, error.WorktreeHasNoAgent => exit_not_found,
            else => exit_failure,
        };
    };
}

fn execute(session: *Session, options: AgentOptions, output: ExecutionContext) !u8 {
    if (options.action == .report_title or options.action == .report_state or options.action == .report_command) {
        var reports: AgentReports = .{ .session = session, .options = options, .output = output };
        try reports.run();
        return exit_ok;
    }

    var snapshot: Snapshot = .{ .catalog = output.catalog };
    try session.fetchAgents(&snapshot);

    switch (options.action) {
        .report_title, .report_state, .report_command => unreachable,
        .list => {
            try writeList(output.writer, &snapshot, options.json);
            return exit_ok;
        },
        .get => {
            const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            try writeOne(output.writer, agent, options.json);
            return exit_ok;
        },
        .acknowledge => {
            const target = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            const pane: PaneRef = .{ .pane_id = target.pane_id, .pane_generation = target.pane_generation };
            try session.acknowledge(pane);
            try session.fetchAgents(&snapshot);
            const updated = try snapshot.resolve(.{ .pane = pane.pane_id }, output.environ) orelse return error.AgentNotFound;
            if (updated.pane_generation != pane.pane_generation) {
                return error.AgentNotFound;
            }

            if (updated.status == .done) {
                return error.AgentAcknowledgementNotApplied;
            }

            try writeOne(output.writer, updated, options.json);
            return exit_ok;
        },
        .wait => return waitFor(session, options, output),
        .prompt => return prompt(session, options, output),
        .interrupt => {
            const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            try session.interruptAgent(.{ .pane_id = agent.pane_id, .pane_generation = agent.pane_generation });
            try writeOne(output.writer, agent, options.json);
            return exit_ok;
        },
        .report_session => {
            const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            try session.reportSession(.{
                .pane_id = agent.pane_id,
                .pane_generation = agent.pane_generation,
            }, std.mem.span(options.text.?));
            return exit_ok;
        },
        .read => {
            const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            const text = try session.readPane(.{
                .pane_id = agent.pane_id,
                .pane_generation = agent.pane_generation,
            }, .{ .rows = options.lines, .source = options.source });
            try writeText(output.writer, text, options.json);
            return exit_ok;
        },
    }
}

fn waitFor(session: *Session, options: AgentOptions, output: ExecutionContext) !u8 {
    const deadline = session.nowMs() + @as(i64, options.timeout_seconds) * std.time.ms_per_s;
    var snapshot: Snapshot = .{ .catalog = output.catalog };

    while (true) {
        try session.fetchAgents(&snapshot);
        const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
        if (options.until.matches(agent.status)) {
            try writeOne(output.writer, agent, options.json);
            return exit_ok;
        }

        if (session.nowMs() >= deadline) {
            std.debug.print("telar agent: timed out after {d}s; agent is {s}\n", .{
                options.timeout_seconds,
                control.statusName(agent.status),
            });
            return exit_timeout;
        }

        session.sleepMs(poll_interval_ms);
    }
}

fn prompt(session: *Session, options: AgentOptions, output: ExecutionContext) !u8 {
    var snapshot: Snapshot = .{ .catalog = output.catalog };
    try session.fetchAgents(&snapshot);
    const target = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
    const pane: PaneRef = .{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
    };
    if (options.interrupt_first and target.status == .working) {
        try interruptAndSettle(session, pane, &snapshot);
    }

    const sender = control.currentPaneId(output.environ) catch null;
    try session.sendText(pane, .{
        .mode = .prompt,
        .text = std.mem.span(options.text.?),
        .sender = if (sender == pane.pane_id) null else sender,
    });

    if (!options.wait_after_prompt) {
        return exit_ok;
    }

    // The agent must visibly start working before the wait for its completion
    // begins; otherwise a dropped prompt would be reported as an instant success.
    const start_deadline = session.nowMs() + prompt_start_grace_ms;
    var started = false;
    const deadline = session.nowMs() + @as(i64, options.timeout_seconds) * std.time.ms_per_s;
    while (true) {
        try session.fetchAgents(&snapshot);
        const agent = try snapshot.resolve(.{ .pane = pane.pane_id }, output.environ) orelse return error.AgentNotFound;
        if (agent.pane_generation != pane.pane_generation) {
            return error.AgentNotFound;
        }

        if (agent.status == .working) {
            started = true;
        } else if (started or agent.status == .blocked or agent.status == .failed) {
            try writeOne(output.writer, agent, options.json);
            return if (agent.status == .failed) exit_failure else exit_ok;
        } else if (session.nowMs() >= start_deadline) {
            std.debug.print("telar agent: the agent did not start working within {d}s\n", .{prompt_start_grace_ms / std.time.ms_per_s});
            return exit_timeout;
        }

        if (session.nowMs() >= deadline) {
            std.debug.print("telar agent: timed out after {d}s; agent is still working\n", .{options.timeout_seconds});
            return exit_timeout;
        }

        session.sleepMs(poll_interval_ms);
    }
}

/// Interrupts a working agent and waits until its turn stopped, so the
/// prompt that follows starts a new turn instead of queueing behind the old.
fn interruptAndSettle(session: *Session, pane: PaneRef, snapshot: *Snapshot) !void {
    try session.interruptAgent(pane);
    const deadline = session.nowMs() + interrupt_settle_ms;
    while (session.nowMs() < deadline) {
        session.sleepMs(poll_interval_ms);
        try session.fetchAgents(snapshot);
        const agent = try snapshot.resolve(.{ .pane = pane.pane_id }, .empty) orelse return error.AgentNotFound;
        if (agent.status != .working) {
            return;
        }
    }

    return error.InterruptNotSettled;
}

fn writeList(writer: *std.Io.Writer, snapshot: *const Snapshot, json: bool) !void {
    if (json) {
        try writer.print("{{\"revision\":{d},\"agents\":[", .{snapshot.revision});
        for (snapshot.slice(), 0..) |*agent, index| {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try control.writeAgentJson(writer, agent);
        }
        try writer.writeAll("]}\n");
        return;
    }

    try writer.writeAll(control.agent_row_header);
    for (snapshot.slice()) |*agent| {
        try control.writeAgentRow(writer, agent);
    }
}

fn writeOne(writer: *std.Io.Writer, agent: *const ControlAgent, json: bool) !void {
    if (json) {
        try control.writeAgentJson(writer, agent);
        try writer.writeByte('\n');
        return;
    }

    try writer.writeAll(control.agent_row_header);
    try control.writeAgentRow(writer, agent);
}

fn writeText(writer: *std.Io.Writer, text: Text, json: bool) !void {
    if (json) {
        try writer.print("{{\"pane_id\":{d},\"truncated\":{},\"text\":", .{ text.pane_id, text.truncated });
        try control.writeJsonString(writer, text.text);
        try writer.writeAll("}\n");
        return;
    }

    try writer.writeAll(text.text);
    if (text.text.len != 0 and text.text[text.text.len - 1] != '\n') {
        try writer.writeByte('\n');
    }
    if (text.truncated) {
        std.debug.print("telar agent: older rows were omitted\n", .{});
    }
}
