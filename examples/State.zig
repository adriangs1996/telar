const Task = @import("Task.zig");
const Tab = @import("Tab.zig");
const Hint = @import("Hint.zig");
const sidebar = @import("sidebar.zig");
const GenericField = @import("telar-client").GenericField;
const PositionType = @import("telar-frontend").Position;
const RangeType = @import("telar-core").Range;
const ClickTrackerType = @import("telar-core").ClickTracker;
const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const ScreenStats = @import("telar-frontend").ScreenStats;
const PacerStats = @import("telar-frontend").PacerStats;
const State = @This();

tasks: []const Task,
tabs: []const Tab,
hints: []const Hint,

selected_tab: usize = 0,
selected_task: usize = 0,
hovered: ?sidebar.Action = null,
scroll: u16 = 0,
scope_open: bool = false,
/// The search box. Editable whenever it holds the keyboard - there is no
/// separate "search mode", because focus already answers that question.
search: GenericField(256) = .init(""),
/// Inside a bracketed paste, so a newline is text rather than Enter.
pasting: bool = false,
/// Which task's dialog is open, if any.
dialog: ?usize = null,
/// Set by an action so the footer can show what happened. A real one would
/// open a dialog.
flash: []const u8 = "",

hits: sidebar.Hits = .{},
/// Opens on the list, not in the search box: a UI whose first keystroke has
/// to be Tab before any shortcut works is a UI that feels broken.
focus: sidebar.FocusReg = .{ .initial = .{ .task = 0 } },
/// Where the real cursor should go this frame, set by whatever is editable.
cursor: ?PositionType = null,

/// The drag in progress or the one just finished.
selection: ?RangeType = null,
dragging: bool = false,
clicks: ClickTrackerType = .{},
/// Text waiting to go to the clipboard, and how much of it there is.
///
/// Handed to the loop rather than written here: `update` has no writer and
/// keeping it that way is what makes every interaction testable.
clipboard: [4096]u8 = undefined,
clipboard_len: usize = 0,

/// The buffer the last frame drew into, for reading text back out of.
///
/// A selection is over what the user can see, and what they can see is the
/// last frame. Re-deriving it from the model would copy something subtly
/// different from what is on screen.
last_buffer: ?*const BufferType = null,

/// Monotonic nanoseconds, set by the loop before each batch.
///
/// Time as data rather than as a call. Double click is a timing fact, and a
/// handler that reads a clock cannot be tested without one.
now: u64 = 0,
list_area: RectType = .{},
total_rows: u16 = 0,

frames: u64 = 0,
last_frame: ScreenStats = .{},
pacing: PacerStats = .{},
quit: bool = false,
