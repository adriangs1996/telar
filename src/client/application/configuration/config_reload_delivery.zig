//! Application policy for delivering one resolved configuration reload.

const DiagnosticType = @import("../../config/Diagnostic.zig");
const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const std = @import("std");

pub const Resolution = union(enum) {
    unchanged,
    rejected: DiagnosticType,
    adopted,
};

pub const Outcome = union(enum) {
    unchanged,
    rejected,
    adopted: ConfigurationCommitType,
};

pub const Event = enum {
    apply_adoption,
    publish_notification,
    rearm,
};

pub const Failure = enum {
    none,
    apply_adoption,
    publish_notification,
    rearm,
};

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
    value.set("{s}", .{text});

    return value;
}

fn invalidDiagnostic() DiagnosticType {
    var value: DiagnosticType = .{};
    value.buffer[0] = 0xff;
    value.len = 1;

    return value;
}
