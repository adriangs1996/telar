//! Owns one asynchronous reservation and rejects obsolete completions.
const std = @import("std");
const types = @import("types.zig");
const attachments = @import("../attachments/root.zig");
const PluginExecution = types.PluginExecution;
const PluginExecutionId = types.PluginExecutionId;
pub const ClipboardCapture = types.ClipboardCapture;
pub const ClipboardCaptureId = types.ClipboardCaptureId;

pub const State = @import("ClipboardCaptureState.zig");
