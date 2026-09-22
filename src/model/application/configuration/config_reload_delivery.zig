//! Application policy for delivering one resolved configuration reload.

const DiagnosticType = @import("../../config/Diagnostic.zig");
const ConfigurationCommitType = @import("../../state/ConfigurationCommit.zig");

pub const Resolution = @import("../../types/ConfigReloadResolution.zig").ConfigReloadResolution;

pub const Outcome = @import("../../types/ConfigReloadOutcome.zig").ConfigReloadOutcome;

pub const Event = @import("../../types/ConfigReloadEvent.zig").ConfigReloadEvent;

pub const Failure = @import("../../types/ConfigReloadFailure.zig").ConfigReloadFailure;

pub fn testingCommit() ConfigurationCommitType {
    return .{
        .generation = 2,
        .configuration_revision = 1,
        .sidebar = null,
        .pane_gaps_changed = false,
        .panes_revision = 0,
    };
}

fn makeDiagnostic(text: []const u8) DiagnosticType {
    var value: DiagnosticType = .{};
    value.set(
        "{s}",
        .{
            text,
        },
    );

    return value;
}

fn invalidDiagnostic() DiagnosticType {
    var value: DiagnosticType = .{};
    value.buffer[0] = 0xff;
    value.len = 1;

    return value;
}
