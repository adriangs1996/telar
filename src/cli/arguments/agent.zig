//! Agent command grammar and validated options.

pub const AgentAction = enum { list, get, wait, prompt, read, interrupt, report_session, report_title, report_state, report_command, acknowledge };
