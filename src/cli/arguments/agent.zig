//! Agent command grammar and validated options.

pub const AgentAction = enum { list, get, wait, prompt, read, report_session, interrupt, thread, models, skills, conversations, approvals, approve, reject, clear, rename, history, watch, report_title, report_state, report_command };
