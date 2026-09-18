//! Pane process ownership: terminal sessions own a PTY; agent sessions own pipes.
const std = @import("std");
const Terminal = @import("../pty/Session.zig");
const AgentProcess = @import("AgentProcess.zig");
const Size = @import("../pty/Size.zig");
const Exit = @import("../pty/exit.zig").Exit;

pub const Process = union(enum) {
    terminal: Terminal,
    agent: AgentProcess,

    /// Example: `const pid = process.processId();`
    pub fn processId(process: *const Process) std.c.pid_t {
        return switch (process.*) {
            .terminal => |*session| session.processId(),
            .agent => 0,
        };
    }

    /// Example: `const count = try process.read(io, buffer);`
    pub fn read(process: *const Process, io: std.Io, buffer: []u8) !usize {
        return switch (process.*) {
            .terminal => |*session| session.read(io, buffer),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `try process.writeAll(io, bytes);`
    pub fn writeAll(process: *const Process, io: std.Io, bytes: []const u8) !void {
        return switch (process.*) {
            .terminal => |*session| session.writeAll(io, bytes),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `const active = process.shellForeground();`
    pub fn shellForeground(process: *const Process) ?bool {
        return switch (process.*) {
            .terminal => |*session| session.shellForeground(),
            .agent => null,
        };
    }

    /// Example: `const group = process.foregroundProcessGroup();`
    pub fn foregroundProcessGroup(process: *const Process) ?std.c.pid_t {
        return switch (process.*) {
            .terminal => |*session| session.foregroundProcessGroup(),
            .agent => null,
        };
    }

    /// Example: `try process.resize(size);`
    pub fn resize(process: *Process, size: Size) !void {
        switch (process.*) {
            .terminal => |*session| try session.resize(size),
            .agent => {},
        }
    }

    /// Example: `const exit = try process.wait();`
    pub fn wait(process: *Process) !Exit {
        return switch (process.*) {
            .terminal => |*session| session.wait(),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `process.shutdown();`
    pub fn shutdown(process: *Process) void {
        switch (process.*) {
            .terminal => |*session| session.shutdown(),
            .agent => |agent| agent.session.stop(agent.io),
        }
    }

    /// Example: `process.deinit();`
    pub fn deinit(process: *Process) void {
        switch (process.*) {
            .terminal => |*session| session.deinit(),
            .agent => |agent| agent.session.close(agent.io),
        }
    }
};
