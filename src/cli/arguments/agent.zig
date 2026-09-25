//! Agent command grammar and validated options.

pub const AgentAction = enum { list, get, wait, prompt, read, report_session, report_title, report_state, report_command, acknowledge };
