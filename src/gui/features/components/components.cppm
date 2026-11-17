// The components a configuration puts in the bars, panels, picks and slots of the chrome: what
// they define, the content and element trees a render produces, and the options of a pick. The
// configuration's generation holds them and runs the interpreter that renders them, so the
// feature has no state of the session's: its types are its interface.
export module telar.gui.features.components;

export import :content;
export import :context;
export import :definitions;
export import :elements;
export import :picks;
export import :rendered;
