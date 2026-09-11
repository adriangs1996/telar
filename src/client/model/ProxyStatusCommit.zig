const ProxyStatusCommit = @This();
const source_namespace = @import("types.zig");
previous: bool,
previous_scope: source_namespace.schema.ProxyScope,
previous_system_trusted: bool,
active: bool,
scope: source_namespace.schema.ProxyScope,
system_trusted: bool,
proxy_status_revision_before: u64,
proxy_status_revision: u64,
