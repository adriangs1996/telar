const core = @import("telar-core");
const EditorOpening = @This();

pending: ?core.OwnedEditorOpen = null,

/// Retains one file until its exact runtime reply arrives. Example: `try state.begin(request);`
pub fn begin(self: *EditorOpening, request: core.OwnedEditorOpen) !void {
    if (self.pending != null) {
        return error.EditorOpenBusy;
    }

    self.pending = request;
}

/// A stale or duplicate reply cannot consume a newer click. Example: `const request = state.complete(id) orelse return;`
pub fn complete(self: *EditorOpening, request_id: core.RequestId) ?core.OwnedEditorOpen {
    const pending = self.pending orelse return null;
    if (pending.request_id != request_id) {
        return null;
    }

    self.pending = null;
    return pending;
}
