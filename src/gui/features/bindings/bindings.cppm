// The keys the user binds: what a press does before it reaches the terminal, and how the chrome
// names a binding. Each window holds its router and routes every key through it, so the feature
// has no state of the session's: its types are its interface.
export module telar.gui.features.bindings;

export import :labels;
export import :router;
