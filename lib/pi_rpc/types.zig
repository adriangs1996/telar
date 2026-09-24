//! Bounds and outcomes shared by the service and its session. Prompts and
//! replies are bounded so a request never allocates on its way in or out.

pub const max_prompt_bytes = 8 * 1024;
pub const max_reply_bytes = 4 * 1024;
pub const max_pending_requests = 8;

pub const Status = enum {
    success,
    /// The command could not start at all.
    unavailable,
    timeout,
    /// The engine answered, but not with usable text.
    invalid_output,
    failed,
};
