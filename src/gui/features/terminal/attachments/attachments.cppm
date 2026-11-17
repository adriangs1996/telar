// Images attached to a pane's prompt: the clipboard image captured into the shelf, the markers
// the prompt shows for them, and the modal that shows one. The shelf and its catalog belong to
// the window that shows them, so the feature has no session state: its types are its interface.
export module telar.gui.features.terminal.attachments;

export import :catalog;
export import :capture;
export import :presentation;
