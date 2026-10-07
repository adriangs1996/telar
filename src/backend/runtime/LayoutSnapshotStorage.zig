const core = @import("telar-core");

// SAFETY: ClientLayouts.snapshot writes each retained tab before returning the initialized prefix.
tabs: [core.max_client_layout_tabs]core.ClientTabLayout = undefined,
