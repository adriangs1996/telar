// The components as ui draws them: what a configuration defines for the bars, panels, picks and
// slots, the content and element trees a render produced, and the options of a pick. The
// configuration's generation renders them on its own thread, so these are types ui holds, not
// use cases of a session.
export module telar.gui.application:components;

import telar.gui.features.components;

export namespace telar::gui::application::components {

  using features::components::BarContent;
  using features::components::builtinContent;
  using features::components::builtinSource;
  using features::components::Capacity;
  using features::components::Clock;
  using features::components::Content;
  using features::components::Context;
  using features::components::Definitions;
  using features::components::Element;
  using features::components::element_kind_names;
  using features::components::ElementColor;
  using features::components::ElementKind;
  using features::components::Icon;
  using features::components::Kind;
  using features::components::Node;
  using features::components::PanelContent;
  using features::components::PickItems;
  using features::components::PickMatches;
  using features::components::Position;
  using features::components::RenderedContent;
  using features::components::RenderedElements;
  using features::components::ResolvedActions;
  using features::components::ResolvedEffects;
  using features::components::Slot;
  using features::components::slot_names;
  using features::components::Source;
  using features::components::SourceKind;
  using features::components::Time;

}
