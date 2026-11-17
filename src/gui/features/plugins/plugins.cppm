// The plugins a configuration names: their catalog and the pages a client reads of it, the
// overrides a client sets, and the run of an action with the effects it returns. Reading the
// packages and the trust store from disk and running a plugin are the shell's, so the feature
// has no state of the session's: its types are its interface.
export module telar.gui.features.plugins;

export import :catalog;
export import :effects;
