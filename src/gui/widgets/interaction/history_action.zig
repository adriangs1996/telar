//! Native history controls keep selection separate from command submission.
const core = @import("telar-core");
const data = @import("model");
const HistoryChoice = @import("HistoryChoice.zig");

pub const Action = union(enum) {
    select: HistoryChoice,
    submit: HistoryChoice,
    /// The submit whose Enter behavior is the configured opposite.
    submit_alternate: HistoryChoice,
    cycle_scope,
    select_scope: data.PromptHistoryScope,
    select_author: core.HistoryAuthorFilter,
    toggle_failed,
    toggle_inspection,
    /// The row above the oldest command, asking for the previous page.
    page_older,
    copy,
    remove,
    visit_pane,
};
