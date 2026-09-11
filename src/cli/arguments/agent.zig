//! Agent command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;
const values = @import("values.zig");
pub const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
pub const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
pub const parseWaitStatus = values.parseWaitStatus;
pub const parseTimeoutSeconds = values.parseTimeoutSeconds;
pub const parseLineCount = values.parseLineCount;
pub const parseTextSource = values.parseTextSource;

pub const AgentAction = enum { list, get, wait, prompt, read, report_session };

pub const AgentOptions = @import("AgentOptions.zig");
