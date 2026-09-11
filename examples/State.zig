const State = @This();
const Task = @import("Task.zig");
const Tab = @import("Tab.zig");
const Hint = @import("Hint.zig");
const source_namespace = @import("sidebar.zig");
tasks: []const Task,
tabs: []const Tab,
hints: []const Hint,

selected_tab: usize = 0,
selected_task: usize = 0,
hovered: ?source_namespace.Action = null,
scroll: u16 = 0,
scope_open: bool = false,
/// The search box. Editable whenever it holds the keyboard - there is no
/// separate "search mode", because focus already answers that question.
search: source_namespace.edit.Field(256) = .init(""),
/// Inside a bracketed paste, so a newline is text rather than Enter.
pasting: bool = false,
/// Which task's dialog is open, if any.
dialog: ?usize = null,
/// Set by an action so the footer can show what happened. A real one would
/// open a dialog.
flash: []const u8 = "",

hits: source_namespace.Hits = .{},
/// Opens on the list, not in the search box: a UI whose first keystroke has
/// to be Tab before any shortcut works is a UI that feels broken.
focus: source_namespace.FocusReg = .{ .initial = .{ .task = 0 } },
/// Where the real cursor should go this frame, set by whatever is editable.
cursor: ?source_namespace.term.Screen.Position = null,

/// The drag in progress or the one just finished.
selection: ?source_namespace.sel.Range = null,
dragging: bool = false,
clicks: source_namespace.sel.ClickTracker = .{},
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
last_buffer: ?*const source_namespace.ui.Buffer = null,

/// Monotonic nanoseconds, set by the loop before each batch.
///
/// Time as data rather than as a call. Double click is a timing fact, and a
/// handler that reads a clock cannot be tested without one.
now: u64 = 0,
list_area: source_namespace.ui.Rect = .{},
total_rows: u16 = 0,

frames: u64 = 0,
last_frame: source_namespace.term.Screen.Stats = .{},
pacing: source_namespace.pace.Pacer.Stats = .{},
quit: bool = false,
