// The terminal's input from the pointer: what a pane's program hears of the mouse and the wheel.
// Each terminal holds its own gesture and encoder, read on every pointer event, so the feature
// has no state of the session's: its types are its interface.
export module telar.gui.features.terminal.input;

export import :child_mouse;
export import :mouse_encoder;
