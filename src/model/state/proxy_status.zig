//! The proxy status the runtime reports, reconciled into the client model.

const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("ClientModel.zig");

/// Commits one changed runtime proxy state. Repeated values produce no
/// effect or presentation work.
///
/// ```zig
/// const commit = proxy_status.reconcile(model, .{ .active = true, .scope = .exact, .system_trusted = false }) orelse return;
/// ```
pub fn reconcile(model: *ClientModel, status: core.ProxyStatus) ?model_data.ProxyStatusCommit {
    if (model.proxy_tls_active == status.active and model.proxy_tls_scope == status.scope and model.proxy_system_trusted == status.system_trusted) {
        return null;
    }

    const previous = model.proxy_tls_active;
    const previous_scope = model.proxy_tls_scope;
    const previous_system_trusted = model.proxy_system_trusted;
    const proxy_status_revision_before = model.proxy_status_revision;
    model.proxy_tls_active = status.active;
    model.proxy_tls_scope = status.scope;
    model.proxy_system_trusted = status.system_trusted;
    model.proxy_status_revision +%= 1;

    return .{
        .previous = previous,
        .previous_scope = previous_scope,
        .previous_system_trusted = previous_system_trusted,
        .active = status.active,
        .scope = status.scope,
        .system_trusted = status.system_trusted,
        .proxy_status_revision_before = proxy_status_revision_before,
        .proxy_status_revision = model.proxy_status_revision,
    };
}
