const core = @import("telar-core");

previous: bool,
previous_scope: core.ProxyScope,
active: bool,
scope: core.ProxyScope,
system_trusted: bool,
proxy_status_revision: u64,
