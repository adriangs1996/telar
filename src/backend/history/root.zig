//! Public command-history namespace.

const std = @import("std");
const model_mod = @import("model.zig");
const service_mod = @import("service.zig");
const terminal_mod = @import("terminal.zig");

pub const model = model_mod;
pub const osc = @import("osc.zig");
pub const terminal = terminal_mod;
pub const observer = @import("observer.zig");
pub const prompt_scan = @import("prompt_scan.zig");
pub const detection = @import("agent_detection.zig");
pub const escape = @import("escape.zig");

pub const Service = service_mod.Service;
pub const Tracker = terminal_mod.Tracker;
pub const Command = terminal_mod.Command;
pub const Clock = terminal_mod.Clock;
pub const Status = terminal_mod.Status;
pub const Query = model_mod.Query;
pub const Response = model_mod.Response;
pub const SessionId = model_mod.SessionId;
pub const LaunchPhase = model_mod.LaunchPhase;

test {
    std.testing.refAllDecls(@This());
}
