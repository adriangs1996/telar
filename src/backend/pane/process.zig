//! Pane process ownership: terminal sessions own a PTY; agent sessions own pipes.
const pty = @import("pty");
const exit = pty.exit;
const std = @import("std");
const Terminal = pty.Session;
const AgentProcess = @import("AgentProcess.zig");
const Size = pty.Size;

pub const Process = union(enum) {
    terminal: Terminal,
    agent: AgentProcess,

    /// Example: `const pid = process.processId();`
    pub fn processId(self: *const Process) std.c.pid_t {
        return switch (self.*) {
            .terminal => |*session| session.processId(),
            .agent => 0,
        };
    }

    /// Example: `const count = try process.read(io, buffer);`
    pub fn read(self: *const Process, io: std.Io, buffer: []u8) !usize {
        return switch (self.*) {
            .terminal => |*session| session.read(io, buffer),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `try process.writeAll(io, bytes);`
    pub fn writeAll(self: *const Process, io: std.Io, bytes: []const u8) !void {
        return switch (self.*) {
            .terminal => |*session| session.writeAll(io, bytes),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `const active = process.shellForeground();`
    pub fn shellForeground(self: *const Process) ?bool {
        return switch (self.*) {
            .terminal => |*session| session.shellForeground(),
            .agent => null,
        };
    }

    /// Example: `const group = process.foregroundProcessGroup();`
    pub fn foregroundProcessGroup(self: *const Process) ?std.c.pid_t {
        return switch (self.*) {
            .terminal => |*session| session.foregroundProcessGroup(),
            .agent => null,
        };
    }

    /// Example: `try process.resize(size);`
    pub fn resize(self: *Process, size: Size) !void {
        switch (self.*) {
            .terminal => |*session| try session.resize(size),
            .agent => {},
        }
    }

    /// Example: `const exit = try process.wait();`
    pub fn wait(self: *Process) !exit.Exit {
        return switch (self.*) {
            .terminal => |*session| session.wait(),
            .agent => error.NotATerminal,
        };
    }

    /// Example: `process.shutdown();`
    pub fn shutdown(self: *Process) void {
        switch (self.*) {
            .terminal => |*session| session.shutdown(),
            .agent => |agent| agent.session.stop(agent.io),
        }
    }

    /// Example: `process.deinit();`
    pub fn deinit(self: *Process) void {
        switch (self.*) {
            .terminal => |*session| session.deinit(),
            .agent => |agent| agent.session.close(agent.io),
        }
    }
};
