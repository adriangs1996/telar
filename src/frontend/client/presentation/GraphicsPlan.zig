const core = @import("telar-core");
const client = @import("telar-client");
const SidebarFocus = @import("../../graphics/SidebarFocus.zig");
const SidebarProviderPlacement = @import("../../graphics/SidebarProviderPlacement.zig");
const Plan = @import("../../ui/Plan.zig");
const PresentationPlan = @import("../../presentation/Plan.zig");
const GraphicsPlan = @This();

toast_area: core.Rect = .{},
sidebar_area: core.Rect = .{},
focused_card: ?SidebarFocus = null,
provider_marks: [core.max_agent_snapshot_entries]SidebarProviderPlacement = undefined,
provider_mark_count: u8 = 0,
icons: Plan = .{},
attachments: client.Plan = .{},
modal_area: core.Rect = .{},
pill_labels: PresentationPlan = .{},
