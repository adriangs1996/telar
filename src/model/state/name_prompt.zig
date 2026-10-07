//! Bounded name-prompt state and pure editing transitions.
const textfield = @import("textfield");

const core = @import("telar-core");
const GenericField = textfield.GenericField;
const OwnedHistoryQuery = @import("../connection/OwnedHistoryQuery.zig");
const std = @import("std");

/// Bytes a prompt field holds: a suggestion request, a peek message or a
/// workspace name typed from scratch. Targets that submit less stop at
/// their own bound (`limit`).
pub const max_field_bytes = core.max_suggestion_request_bytes;
pub const Field = GenericField(max_field_bytes);
/// The working-directory field of the new-context form.
pub const DirectoryField = GenericField(core.max_cwd_bytes);

pub const Target = @import("PromptTarget.zig").PromptTarget;

const field_limit = core.Limit.declare("prompt.field_bytes", "bytes", max_field_bytes);
const tab_label_limit = core.Limit.declare("prompt.tab_label_bytes", "bytes", core.max_tab_label_bytes);
const search_needle_limit = core.Limit.declare("prompt.search_needle_bytes", "bytes", core.max_search_needle_bytes);
const path_query_limit = core.Limit.declare("prompt.path_query_bytes", "bytes", core.max_path_query_bytes);
const history_query_limit = core.Limit.declare("prompt.history_query_bytes", "bytes", OwnedHistoryQuery.max_query_bytes);
const machine_label_limit = core.Limit.declare("prompt.machine_label_bytes", "bytes", core.MachineProfile.max_label_bytes);
const machine_destination_limit = core.Limit.declare("prompt.machine_destination_bytes", "bytes", core.ssh_destination.max_bytes);
/// The limit the new-context form's directory field stops at.
pub const directory_limit = core.Limit.declare("prompt.directory_bytes", "bytes", core.max_cwd_bytes);

/// The limit a prompt's text stops at: the bound of what it submits, or
/// the field's own capacity. Input past it keeps what fits and reports it.
///
/// ```zig
/// const room = name_prompt.limit(prompt.target()).value;
/// ```
pub fn limit(target: Target) core.Limit {
    return switch (target) {
        .rename_tab => tab_label_limit,
        .copy_search => search_needle_limit,
        .paths => path_query_limit,
        .history => history_query_limit,
        .machine => |machine| switch (machine) {
            .rename, .add_label => machine_label_limit,
            .add_destination => machine_destination_limit,
        },
        .create_workspace, .rename_workspace, .goto, .suggest, .palette, .peek, .pick => field_limit,
    };
}

comptime {
    // Every target's bound fits the field it types into.
    for ([_]u64{ core.max_tab_label_bytes, core.max_search_needle_bytes, core.max_path_query_bytes, OwnedHistoryQuery.max_query_bytes, core.MachineProfile.max_label_bytes, core.ssh_destination.max_bytes }) |bound| {
        std.debug.assert(bound <= max_field_bytes);
    }
}

pub const Begin = @import("PromptBegin.zig").PromptBegin;

pub const HistoryScope = @import("PromptHistoryScope.zig").PromptHistoryScope;

pub const Command = @import("PromptCommand.zig").PromptCommand;

/// Targets whose prompt drives a list selection instead of a plain name.
/// The suggestion palette lists one row, so Enter on an empty field can
/// still paste it.
pub fn selects(target: Target) bool {
    return target == .goto or target == .history or target == .suggest or target == .palette or target == .paths or target == .pick;
}

/// Targets that act on Enter with an empty field: list prompts pick their
/// row, and a peek opens its agent's tab.
pub fn acceptsEmpty(target: Target) bool {
    return selects(target) or target == .peek;
}
