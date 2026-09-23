const client = @import("telar-client");
const std = @import("std");
const core = @import("telar-core");
const Selector = @import("interaction/ComposerSelector.zig");
const Options = @This();

thread: client.ThreadView,
kind: @FieldType(Selector, "kind"),

/// Uses only entries advertised by the live provider. Example: `const count = options.count();`
pub fn count(self: Options) u8 {
    const snapshot = self.thread.transcript orelse return 0;
    return switch (self.kind) {
        .recent => if (snapshot.canResume()) snapshot.recent.count else 0,
        .model => @intCast(snapshot.models().len),
        .effort => if (snapshot.findModel(self.thread.options.modelSlice())) |model| @intCast(model.efforts().len) else 0,
        .access => if (snapshot.findModel(self.thread.options.modelSlice()) != null) 3 else 0,
    };
}

/// Borrows an actual model/effort name or a supported sandbox policy. Example: `draw(options.label(index));`
pub fn label(self: Options, index: u8) []const u8 {
    if (index >= self.count()) {
        return "";
    }

    return switch (self.kind) {
        .recent => self.thread.transcript.?.recent.entries[index].titleSlice(),
        .model => self.thread.transcript.?.models()[index].labelSlice(),
        .effort => effortLabel(self.thread.transcript.?.findModel(self.thread.options.modelSlice()).?.efforts()[index].idSlice()),
        .access => accessLabel(@enumFromInt(index)),
    };
}

/// Explains the permissions before the user selects them. Example: `draw(options.detail(index));`
pub fn detail(self: Options, index: u8) []const u8 {
    if (self.kind == .recent) {
        return self.thread.cwd;
    }

    if (self.kind != .access) {
        return "";
    }

    return switch (index) {
        0 => "Inspect files; request approval for changes",
        1 => "Edit this workspace; approve broader access",
        2 => "Unrestricted filesystem and network access",
        else => "",
    };
}

/// Example: `const selected = options.selected();`
pub fn selected(self: Options) u8 {
    const snapshot = self.thread.transcript orelse return 0;
    switch (self.kind) {
        .recent => return 0,
        .model => for (snapshot.models(), 0..) |model, index| {
            if (std.mem.eql(u8, model.idSlice(), self.thread.options.modelSlice())) {
                return @intCast(index);
            }
        },
        .effort => if (snapshot.findModel(self.thread.options.modelSlice())) |model| {
            for (model.efforts(), 0..) |effort, index| {
                if (effort.eql(self.thread.options.effort)) {
                    return @intCast(index);
                }
            }
        },
        .access => return @intFromEnum(self.thread.options.access),
    }

    return 0;
}

/// Example: `draw(ComposerOptions.effortLabel(effort.idSlice()));`
pub fn effortLabel(id: []const u8) []const u8 {
    const ids = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" };
    const labels = [_][]const u8{ "None", "Minimal", "Low", "Medium", "High", "Extra high", "Max", "Ultra" };
    for (ids, labels) |value, pretty| {
        if (std.mem.eql(u8, value, id)) {
            return pretty;
        }
    }

    return id;
}

/// Example: `draw(ComposerOptions.accessLabel(options.access));`
pub fn accessLabel(access: core.AgentAccess) []const u8 {
    return switch (access) {
        .read_only => "Read only",
        .workspace => "Workspace",
        .full_access => "Full access",
    };
}
