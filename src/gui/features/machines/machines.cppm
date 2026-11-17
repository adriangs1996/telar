// The machines a window reaches: the profiles the user saved, the roster the window lists and
// picks from, how a connection to one fails, and how the chrome shows them. The window holds
// its roster across the sessions of its machines, so the feature has no state of a session's:
// its types are its interface.
export module telar.gui.features.machines;

export import :discovery;
export import :presentation;
export import :profiles;
export import :roster;
