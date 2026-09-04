//! The `telar agent` command family: list, inspect, wait for, prompt and read
//! the agents running in the local runtime.

const std = @import("std");
const core = @import("telar-core");
const control = @import("control.zig");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const AgentOptions = parser.AgentOptions;

const poll_interval_ms = 250;
const prompt_start_grace_ms = 5_000;

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
    var session = try control.Session.open(init, options.socket);
    defer session.close();
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(&session, options, .{ .writer = writer, .environ = init.minimal.environ }) catch |err| {
        std.debug.print("telar agent: {s}\n", .{control.describe(err)});
        return switch (err) {
            error.AgentNotFound, error.PaneNotFound, error.PaneExited => exit_not_found,
            else => exit_failure,
        };
    };
}

const Output = struct {
    writer: *Io.Writer,
    environ: std.process.Environ,
};

fn execute(session: *control.Session, options: AgentOptions, output: Output) !u8 {
    var snapshot: control.Snapshot = .{};
    try session.fetchAgents(&snapshot);

    switch (options.action) {
        .list => {
            try writeList(output.writer, &snapshot, options.json);
            return exit_ok;
        },
        .get => {
            const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
            try writeOne(output.writer, agent, options.json);
            return exit_ok;
        },
        .wait => return waitFor(session, options, output),
        .prompt => return prompt(session, options, output),
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

fn waitFor(session: *control.Session, options: AgentOptions, output: Output) !u8 {
    const deadline = session.nowMs() + @as(i64, options.timeout_seconds) * std.time.ms_per_s;
    var snapshot: control.Snapshot = .{};

    while (true) {
        try session.fetchAgents(&snapshot);
        const agent = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
        if (agent.status == options.until) {
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

fn prompt(session: *control.Session, options: AgentOptions, output: Output) !u8 {
    var snapshot: control.Snapshot = .{};
    try session.fetchAgents(&snapshot);
    const target = try snapshot.resolve(options.target.?, output.environ) orelse return error.AgentNotFound;
    const pane: control.Session.PaneRef = .{
        .pane_id = target.pane_id,
        .pane_generation = target.pane_generation,
    };
    try session.sendText(pane, .prompt, std.mem.span(options.text.?));

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

fn writeList(writer: *Io.Writer, snapshot: *const control.Snapshot, json: bool) !void {
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

fn writeOne(writer: *Io.Writer, agent: *const control.Agent, json: bool) !void {
    if (json) {
        try control.writeAgentJson(writer, agent);
        try writer.writeByte('\n');
        return;
    }

    try writer.writeAll(control.agent_row_header);
    try control.writeAgentRow(writer, agent);
}

fn writeText(writer: *Io.Writer, text: control.Session.Text, json: bool) !void {
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
