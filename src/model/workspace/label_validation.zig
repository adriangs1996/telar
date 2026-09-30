//! Validation for user-supplied tab labels and workspace names.
const std = @import("std");
const core = @import("telar-core");

pub const Kind = enum { new_tab, renamed_tab, workspace };

/// An empty new-tab label asks the runtime to choose its default name.
/// Example: `try label_validation.validate(command.label, .new_tab);`
pub fn validate(text: []const u8, kind: Kind) !void {
    const invalid = switch (kind) {
        .new_tab, .renamed_tab => error.InvalidTabLabel,
        .workspace => error.InvalidWorkspaceName,
    };
    const max_bytes: usize = if (kind == .workspace) core.max_workspace_name_bytes else core.max_tab_label_bytes;
    if ((text.len == 0 and kind != .new_tab) or text.len > max_bytes) {
        return invalid;
    }

    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    for (text) |byte| {
        if (std.ascii.isControl(byte)) {
            return invalid;
        }
    }
}

test "label validation preserves default names, error kinds and byte limits" {
    try validate("", .new_tab);
    try std.testing.expectError(error.InvalidTabLabel, validate("", .renamed_tab));
    try std.testing.expectError(error.InvalidWorkspaceName, validate("", .workspace));
    for (std.enums.values(Kind)) |kind| {
        try validate("código", kind);
        try validate(&(@as([core.max_tab_label_bytes]u8, @splat('x'))), kind);
        try std.testing.expectError(error.InvalidUtf8, validate("\xff", kind));
        const invalid = if (kind == .workspace) error.InvalidWorkspaceName else error.InvalidTabLabel;
        const longest: usize = if (kind == .workspace) core.max_workspace_name_bytes else core.max_tab_label_bytes;
        const oversized: [core.max_workspace_name_bytes + 1]u8 = @splat('x');
        try validate(oversized[0..longest], kind);
        try std.testing.expectError(invalid, validate(oversized[0 .. longest + 1], kind));
        try std.testing.expectError(invalid, validate("line\n", kind));
        try std.testing.expectError(invalid, validate("line\x7f", kind));
    }
}
