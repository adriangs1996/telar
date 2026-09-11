const ProxyScopeType = @import("telar-core").ProxyScope;
const ProxyStatusCommit = @This();

previous: bool,
previous_scope: ProxyScopeType,
previous_system_trusted: bool,
active: bool,
scope: ProxyScopeType,
system_trusted: bool,
proxy_status_revision_before: u64,
proxy_status_revision: u64,
