const Application = @import("Application.zig");
const Context = @import("../../change_review/Context.zig");
const PaneKey = @import("../../pane/PaneKey.zig");

pub fn resolve(application: *Application, key: PaneKey) !Context {
    const pane = application.model.panes.resolve(key) orelse return error.PaneNotFound;
    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }
    if (pane.kind == .agent) {
        const snapshot = pane.agent_thread orelse return error.AgentNotReady;
        return Context.init(key, .codex, snapshot.threadId());
    }
    const provider = application.model.agents.projectedProvider(key);
    const reference = application.model.agents.sessionReference(key) orelse return error.AgentNotReady;
    return Context.init(key, provider, reference.slice());
}
