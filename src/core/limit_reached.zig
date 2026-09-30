//! What both processes share about a reached limit: which errors mean a
//! telar limit ran out, what a reach does to its row, when a notice shows
//! and when a client reports, and the notice text.
const std = @import("std");
const Limit = @import("Limit.zig");
const LimitReach = @import("LimitReach.zig");
const LimitReaches = @import("LimitReaches.zig");
const RecordedReach = @import("RecordedReach.zig");
const ReachTime = @import("ReachTime.zig");

/// Title of every limit notice.
pub const notice_title = "Limit reached";
/// A limit is shown again only after this long; reaches in between count.
pub const show_interval_ms: i64 = 60 * std.time.ms_per_s;
/// A client folds its reaches into one report to the runtime this often.
pub const report_interval_ms: i64 = std.time.ms_per_s;

/// The errors telar raises when one of its own fixed limits runs out. A
/// flow that adds a limit error adds it here; a safety net absorbs exactly
/// these, and `zig build codestyle` fails on an error named like a limit
/// that is in no set. A fixed buffer or writer that overflows returns
/// `NoSpaceLeft` or `WriteFailed`, the same errors a full disk returns, so
/// a flow that can overflow one maps that to a named limit error.
pub const LimitError = error{
    AgentCapacityExceeded,
    AgentLabelTooLong,
    AgentTitleTooLong,
    ArgumentsTooLarge,
    AtlasFull,
    AttachmentGenerationExhausted,
    AttachmentLeaseLimit,
    AttachmentLimitReached,
    AttachmentSelfFull,
    BarCommandExecutionIdExhausted,
    BarCommandOutputTooLong,
    BarCommandTooLong,
    BarTextTooLong,
    BoxQuadBudgetExceeded,
    BufferTooSmall,
    ChangeReviewSessionTooLarge,
    ChangeReviewSnapshotTooLarge,
    ClientIdentityExhausted,
    ClientLimitReached,
    ClientOutboxFull,
    ClipboardCaptureIdExhausted,
    ClipboardImageTooLarge,
    ClipboardTooLarge,
    ConfigPathTooLong,
    ConfigStreamTooLarge,
    DestinationTooLong,
    DiagnosticLineTooLong,
    DiagramFrameTooLarge,
    DiagramLimit,
    DiagramTextureTooLarge,
    EditorCommandLimit,
    EntryTooLong,
    EnvironmentTooLarge,
    ErrorMessageTooLarge,
    FontCollectionTooLarge,
    FontSetIdentityExhausted,
    FrameTooLarge,
    GlyphTooLarge,
    GraphicsChunkLimitExceeded,
    GraphicsImageLimitExceeded,
    GraphicsImageLimitReached,
    GraphicsLeaseLimit,
    GraphicsPlacementLimitExceeded,
    GraphicsPlacementLimitReached,
    GraphicsQuotaExceeded,
    HeadlessCellBudgetExceeded,
    HeadlessReceiveTooLarge,
    HostEffectsFull,
    HostRequestIdsExhausted,
    HostRequestsFull,
    ImageQuotaExceeded,
    InboxFull,
    InputTooLarge,
    JsonDepth,
    LengthOverflow,
    LimitExceeded,
    LockNameTooLong,
    MachineCommandTooLong,
    MachineLabelTooLong,
    ManifestTooLarge,
    NativeCellBudgetExceeded,
    NativeInputFull,
    NodeLimitReached,
    NotificationTooLarge,
    OriginTooLong,
    OutputFull,
    PaneGenerationExhausted,
    PaneLimitReached,
    PathEntryTooLong,
    PathTooLong,
    PickItemTooLong,
    PickItemsTooLarge,
    PluginExecutionIdExhausted,
    PluginPackageTooLarge,
    PluginPathTooLong,
    PngTooLarge,
    PresentationIdExhausted,
    ProfileCounterOverflow,
    ProviderFrameTooDeep,
    ProviderFrameTooLarge,
    ProxyInterceptHostsTooLarge,
    ProxyPathTooLong,
    QueryTooLong,
    QueueFull,
    RecordTooLarge,
    ReleaseUrlTooLong,
    RemoteCommandTooLong,
    RemoteOutputTooLong,
    RemoteTelarPathTooLong,
    RequestIdExhausted,
    ResponseQueueFull,
    ReviewCapacity,
    ReviewFileLimit,
    ReviewLineLimit,
    RingFull,
    ScopeTooLong,
    ScreenTooLarge,
    SequenceTooLong,
    SheetFull,
    SshCommandTooLong,
    StreamTooLong,
    SurfaceTooLarge,
    TabLimitReached,
    TextMetadataQuotaExceeded,
    TextMetadataTooLarge,
    TextTooLong,
    TooLarge,
    TooManyActions,
    TooManyAgentEntries,
    TooManyAgents,
    TooManyArguments,
    TooManyBarActions,
    TooManyBarCommandArguments,
    TooManyBarComponents,
    TooManyBarSamples,
    TooManyBindings,
    TooManyBlocks,
    TooManyClientLayoutNodes,
    TooManyClientLayoutTabs,
    TooManyCommandArguments,
    TooManyConfigArguments,
    TooManyDiagnosticLogs,
    TooManyDirectoryEntries,
    TooManyEffects,
    TooManyEntries,
    TooManyEnvironmentEntries,
    TooManyFilterPatterns,
    TooManyFontSizes,
    TooManyHistoryResults,
    TooManyLimits,
    TooManyMachines,
    TooManyPanes,
    TooManyPathResults,
    TooManyPendingClientLayouts,
    TooManyPendingLaunches,
    TooManyPendingRequests,
    TooManyPickItems,
    TooManyPluginCapabilities,
    TooManyPluginEntries,
    TooManyPluginOverrides,
    TooManyPlugins,
    TooManyProxyInterceptHosts,
    TooManyReviewFiles,
    TooManySavedLayouts,
    TooManySearchMatches,
    TooManySpans,
    TooManyTabs,
    TooManyTapPlugins,
    TooManyTrustGrants,
    TooManyWorkerEffects,
    TooManyWorkspaces,
    TooManyWorktrees,
    TopologyLimitReached,
    WidgetIdentityExhausted,
    WindowTitleTooLong,
    WorkspaceCommandTooLong,
    WorkspaceLimitReached,
    WorkspaceListTooLarge,
    WorkspacePathTooLong,
    WorktreeLimitReached,
};

/// Errors the host raises, not a telar limit: memory from a real
/// allocator, a full disk (`NoSpaceLeft`) or quota, descriptor quotas, a
/// name the file system refuses. A net logs them as errors and lets them
/// keep their path.
pub const SystemError = error{
    BrotliOutOfMemory,
    DiskQuota,
    NameTooLong,
    NoSpaceLeft,
    OutOfMemory,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

/// Errors named like a limit that are not one. `zig build codestyle`
/// requires every error named like a limit to be in a set, and each member
/// here to say why it is not a limit.
pub const NotLimitError = error{
    /// A test fixture's own bound, not telar's.
    AckCapacityExceeded,
    /// One command in flight per client by design; the caller answers busy.
    ClientBusy,
    /// A test driver with one operation in flight.
    DriverBusy,
    /// One editor open in flight by design; the caller answers busy.
    EditorOpenBusy,
    /// A test fixture's own bound, not telar's.
    FixtureClientLimit,
    /// Arithmetic on dimensions a child sent: a malformed image.
    ImageSizeOverflow,
    /// A test fixture's own bound, not telar's.
    InputCapacityExceeded,
    /// A configured capture quota out of range: invalid configuration.
    InvalidCaptureQuota,
    /// A configured decode bound out of range: invalid configuration.
    InvalidDecodeLimit,
    /// A profiling workload that does not exist: invalid arguments.
    InvalidFullWorkload,
    /// A configured graphics bound out of range: invalid configuration.
    InvalidGraphicsLimit,
    /// Configured graphics bounds that contradict: invalid configuration.
    InvalidGraphicsLimits,
    /// A configured history bound out of range: invalid configuration.
    InvalidHistoryLimit,
    /// A bound given on the command line out of range: invalid arguments.
    InvalidLimit,
    /// A limit report whose name is not an identifier: an invalid message.
    InvalidLimitName,
    /// A limit report whose noun is not printable: an invalid message.
    InvalidLimitNoun,
    /// A limit list row of an unknown origin: an invalid message.
    InvalidLimitOrigin,
    /// A limit report with no reaches: an invalid message.
    InvalidLimitReport,
    /// A limit report whose route is not an identifier: an invalid message.
    InvalidLimitRoute,
    /// A configured path bound out of range: invalid configuration.
    InvalidPathLimit,
    /// A deadline a test measures, not a bound telar enforces.
    LivePaneInputForwardingDeadlineExceeded,
    /// A deadline a test measures, not a bound telar enforces.
    LivePaneInputReadinessDeadlineExceeded,
    /// A graphics bound the options must name: invalid configuration.
    MissingGraphicsGlobalLimit,
    /// A graphics bound the options must name: invalid configuration.
    MissingGraphicsPaneLimit,
    /// A history bound the options must name: invalid configuration.
    MissingHistoryLimit,
    /// Arithmetic overflow inside a decoder: a malformed input.
    Overflow,
    /// A command for a fullscreen state the pane cannot take.
    PaneFullscreenUnavailable,
    /// A pane too small to split: a geometry answer, not a capacity.
    PaneTooSmall,
    /// One path index build in flight by design; the caller answers busy.
    PathPickerBusy,
    /// A performance gate a benchmark measures, not a bound telar enforces.
    PerformanceBudgetExceeded,
    /// One plugin action in flight by design; the caller answers busy.
    PluginWorkerBusy,
    /// One presentation in flight by design; the next frame waits for it.
    PresentationBusy,
    /// A rate policy answered to the sender, which keeps working.
    PromptRateLimited,
    /// A deadline a test measures, not a bound telar enforces.
    PtyInputForwardingDeadlineExceeded,
    /// A test fixture with one receive in flight.
    ReceiveBusy,
    /// One review job per pane in flight by design; the caller answers busy.
    ReviewBusy,
    /// A window too small to lay out: a geometry answer, not a capacity.
    TerminalTooSmall,
    /// A deadline a test measures, not a bound telar enforces.
    TestReceiveDeadlineExceeded,
    /// A test fixture's own bound, not telar's.
    TestScreenTooLarge,
    /// A test fixture's own bound, not telar's.
    TooManyHiddenPanes,
    /// A test fixture's own bound, not telar's.
    TooManyImagePanes,
};

/// Whether an error is one of telar's own limits (`LimitError`).
///
/// ```zig
/// if (!limit_reached.isLimitError(err)) return err;
/// ```
pub fn isLimitError(err: anyerror) bool {
    return inSet(LimitError, err);
}

/// Whether an error comes from the host rather than a telar limit.
/// Example: `if (limit_reached.isSystemError(err)) log.err(...);`
pub fn isSystemError(err: anyerror) bool {
    return inSet(SystemError, err);
}

fn inSet(comptime Set: type, err: anyerror) bool {
    inline for (@typeInfo(Set).error_set.?) |member| {
        if (err == @field(anyerror, member.name)) {
            return true;
        }
    }

    return false;
}

/// The reach a safety net reports for a limit error nobody named: the
/// error's name stands in for the limit's, and `route` says which net.
///
/// ```zig
/// limit_reached.report(model, limit_reached.unnamed(err, "agent_tick"));
/// ```
pub fn unnamed(err: anyerror, route: []const u8) LimitReach {
    const name = @errorName(err);
    return .{
        .limit = .{
            .name = name[0..@min(name.len, Limit.max_name_bytes)],
            .value = 0,
        },
        .route = route[0..@min(route.len, LimitReach.max_route_bytes)],
    };
}

/// Counts `hits` reaches of one limit at `at` and decides whether to show
/// it: a limit not shown within `show_interval_ms` shows now.
///
/// ```zig
/// const recorded = limit_reached.record(&model.limit_reaches, reach, at, 1);
/// if (recorded.show) { ... }
/// ```
pub fn record(reaches: *LimitReaches, reach: LimitReach, at: ReachTime, hits: u32) RecordedReach {
    const name = reach.limit.name[0..@min(reach.limit.name.len, Limit.max_name_bytes)];
    const slot = reaches.find(name) orelse reaches.insert(name);

    const noun = reach.limit.noun[0..@min(reach.limit.noun.len, Limit.max_noun_bytes)];
    @memcpy(reaches.noun[slot][0..noun.len], noun);
    reaches.noun_len[slot] = @intCast(noun.len);
    const route = reach.route[0..@min(reach.route.len, LimitReach.max_route_bytes)];
    @memcpy(reaches.route[slot][0..route.len], route);
    reaches.route_len[slot] = @intCast(route.len);
    reaches.value[slot] = reach.limit.value;
    if (reach.requested) |requested| {
        reaches.requested[slot] = requested;
    }

    reaches.hits[slot] +|= hits;
    reaches.unreported[slot] +|= hits;
    reaches.last_ms[slot] = at.real_ms;

    const show = if (reaches.shown_ms[slot]) |shown| at.awake_ms - shown >= show_interval_ms else true;
    if (show) {
        reaches.shown_ms[slot] = at.awake_ms;
    }

    return .{
        .slot = slot,
        .show = show,
    };
}

/// Takes the reaches of one row not yet reported to the runtime, at most
/// once per `report_interval_ms`; null while the interval runs.
///
/// ```zig
/// if (limit_reached.takeReport(&model.limit_reaches, slot, awake_ms)) |hits| { ... }
/// ```
pub fn takeReport(reaches: *LimitReaches, slot: usize, awake_ms: i64) ?u32 {
    if (reaches.unreported[slot] == 0) {
        return null;
    }

    if (reaches.reported_ms[slot]) |reported| {
        if (awake_ms - reported < report_interval_ms) {
            return null;
        }
    }

    const hits = reaches.unreported[slot];
    reaches.unreported[slot] = 0;
    reaches.reported_ms[slot] = awake_ms;
    return hits;
}

/// Gives back reaches a report could not carry, so the next one does.
/// Example: `limit_reached.restoreReport(&model.limit_reaches, slot, hits);`
pub fn restoreReport(reaches: *LimitReaches, slot: usize, hits: u32) void {
    reaches.unreported[slot] +|= hits;
    reaches.reported_ms[slot] = null;
}

fn sample(name: []const u8, requested: ?u64) LimitReach {
    return .{
        .limit = .{
            .name = name,
            .noun = "items",
            .value = 4,
        },
        .requested = requested,
    };
}

fn time(awake_ms: i64) ReachTime {
    return .{
        .awake_ms = awake_ms,
        .real_ms = 1_700_000_000_000 + awake_ms,
    };
}

test "limit errors are told apart from host errors and bugs" {
    try std.testing.expect(isLimitError(error.TooManyBarActions));
    try std.testing.expect(isLimitError(error.AtlasFull));
    try std.testing.expect(isLimitError(error.PaneLimitReached));
    try std.testing.expect(isLimitError(error.WidgetIdentityExhausted));
    try std.testing.expect(isLimitError(error.ReviewLineLimit));
    try std.testing.expect(!isLimitError(error.NoSpaceLeft));
    try std.testing.expect(!isLimitError(error.WriteFailed));
    try std.testing.expect(!isLimitError(error.OutOfMemory));
    try std.testing.expect(isSystemError(error.NoSpaceLeft));
    try std.testing.expect(isSystemError(error.DiskQuota));
    try std.testing.expect(!isLimitError(error.InvalidPresentationCommit));

    try std.testing.expect(isSystemError(error.OutOfMemory));
    try std.testing.expect(isSystemError(error.SystemFdQuotaExceeded));
    try std.testing.expect(!isSystemError(error.TooManyTabs));
}

test "a limit is shown once per interval and every reach counts" {
    var reaches: LimitReaches = .{};

    const first = record(&reaches, sample("bars.max_bar_actions", 5), time(1_000), 1);
    try std.testing.expect(first.show);

    const second = record(&reaches, sample("bars.max_bar_actions", 17), time(2_000), 1);
    try std.testing.expect(!second.show);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[first.slot]);
    try std.testing.expectEqual(@as(?u64, 17), reaches.requested[first.slot]);
    try std.testing.expectEqual(time(2_000).real_ms, reaches.last_ms[first.slot]);

    const later = record(&reaches, sample("bars.max_bar_actions", null), time(1_000 + show_interval_ms), 1);
    try std.testing.expect(later.show);
    try std.testing.expectEqual(@as(?u64, 17), reaches.requested[first.slot]);
    try std.testing.expectEqual(@as(u64, 3), reaches.hits[first.slot]);
}

test "reports fold reaches and wait for their interval" {
    var reaches: LimitReaches = .{};
    const slot = record(&reaches, sample("gui.widgets.registry_capacity", null), time(0), 1).slot;

    try std.testing.expectEqual(@as(?u32, 1), takeReport(&reaches, slot, 0));
    _ = record(&reaches, sample("gui.widgets.registry_capacity", null), time(10), 1);
    _ = record(&reaches, sample("gui.widgets.registry_capacity", null), time(20), 1);
    try std.testing.expectEqual(@as(?u32, null), takeReport(&reaches, slot, 20));
    try std.testing.expectEqual(@as(?u32, 2), takeReport(&reaches, slot, report_interval_ms));

    restoreReport(&reaches, slot, 2);
    try std.testing.expectEqual(@as(?u32, 2), takeReport(&reaches, slot, report_interval_ms + 1));
}

test "an unnamed reach carries its error and the net that caught it" {
    const reach = unnamed(error.ChromeHitCapacityExceeded, "window_draw");
    try std.testing.expectEqualStrings("ChromeHitCapacityExceeded", reach.limit.name);
    try std.testing.expectEqualStrings("window_draw", reach.route);
    try reach.validate();
}
