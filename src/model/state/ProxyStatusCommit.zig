const core = @import("telar-core");
const ProxyStatusCommit = @This();

previous: bool,
previous_scope: core.ProxyScope,
previous_system_trusted: bool,
active: bool,
scope: core.ProxyScope,
system_trusted: bool,
proxy_status_revision_before: u64,
proxy_status_revision: u64,
