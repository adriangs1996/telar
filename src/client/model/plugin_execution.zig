//! Owns one asynchronous reservation and rejects obsolete completions.
const std = @import("std");
const types = @import("types.zig");
const attachments = @import("../attachments/root.zig");
pub const PluginExecution = types.PluginExecution;
pub const PluginExecutionId = types.PluginExecutionId;
const ClipboardCapture = types.ClipboardCapture;
const ClipboardCaptureId = types.ClipboardCaptureId;

pub const State = @import("PluginExecutionState.zig");
