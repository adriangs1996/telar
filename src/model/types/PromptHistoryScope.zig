pub const PromptHistoryScope = enum(u8) {
    global = 0,
    workspace = 1,
    cwd = 2,
    pane = 3,

    pub fn next(scope: PromptHistoryScope) PromptHistoryScope {
        return switch (scope) {
            .global => .workspace,
            .workspace => .cwd,
            .cwd => .pane,
            .pane => .global,
        };
    }

    pub fn label(scope: PromptHistoryScope) []const u8 {
        return switch (scope) {
            .global => "global",
            .workspace => "workspace",
            .cwd => "cwd",
            .pane => "pane",
        };
    }
};
