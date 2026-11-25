// The configuration as a client reads it: the themes it names and the sections of a loaded
// configuration, written as JSON. Loading one reads files and runs its interpreter, which the
// shell does; the session holds the configuration it shows as foundation vocabulary, so the
// feature has no state of its own: its types are its interface.
export module telar.gui.features.configuration;

export import :queries;
export import :themes;
export import :theme_picker;
