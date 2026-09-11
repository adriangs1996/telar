//! Application command for an agent reporting its own session reference.

pub const ReportAgentSessionResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_session,
};
