//! Disposable state of the new-context form: which field owns input, the
//! selected path completion and a pending directory confirmation.
const WorkspaceForm = @This();

pub const Focus = enum { name, directory };

focus: Focus = .name,
/// Index into the client's path-completion entries; clamped by the controller.
selection: u16 = 0,
/// Set after a submit found no directory; the next submit asks to create it.
confirm_create: bool = false,
