// The window: its title, its surfaces and geometry on a display, and the pacing of its frames.
// Each window holds its own pacer and cues, read every frame, so the feature has no state of
// the session's: its types are its interface.
export module telar.gui.features.window;

export import :display;
export import :pacer;
export import :title;
