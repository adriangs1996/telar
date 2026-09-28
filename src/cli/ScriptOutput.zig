//! What one command run over SSH printed and how it ended. The caller owns
//! both outputs and frees them with `deinit`.
const std = @import("std");
const ScriptOutput = @This();

term: std.process.Child.Term,
stdout: []u8,
stderr: []u8,

pub fn deinit(self: *const ScriptOutput, gpa: std.mem.Allocator) void {
    gpa.free(self.stdout);
    gpa.free(self.stderr);
}

/// Whether the command exited with status 0.
pub fn succeeded(self: *const ScriptOutput) bool {
    return self.term == .exited and self.term.exited == 0;
}
