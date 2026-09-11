//! Application command for an agent reporting the name its own session
//! carries.

pub const ReportAgentTitleResult = enum {
    recorded,
    unchanged,
    pane_not_found,
    invalid_title,
};
