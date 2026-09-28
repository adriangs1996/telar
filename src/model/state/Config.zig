//! Client settings adopted from the active configuration generation. Startup
//! and every reload write it the same way, so no setting waits for a reload.
const NotificationDelivery = @import("../notifications/NotificationDelivery.zig").NotificationDelivery;
const AppearanceThemes = @import("../appearance/AppearanceThemes.zig");
const Config = @This();

notification_delivery: NotificationDelivery = .telar,
/// Whether the history palette lists automation-submitted commands too.
history_show_agent_commands: bool = false,
/// Whether Enter in the history palette runs the command instead of only
/// pasting it; shift+enter always does the opposite.
history_enter_runs: bool = false,
/// Whether the palette uses trigram substring matching instead of the
/// default fuzzy subsequence matching.
history_match_fts: bool = false,
themes: AppearanceThemes = .{},
