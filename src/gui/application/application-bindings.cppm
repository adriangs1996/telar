// The keys the user binds as ui drives them: the router each window sends every key through and
// the labels the chrome names a binding with. Each window holds its router, so these are types
// ui holds, not use cases of a session.
export module telar.gui.application:bindings;

import telar.gui.features.bindings;

export namespace telar::gui::application::bindings {

  using features::bindings::KeyLabel;
  using features::bindings::KeyLabelStyle;
  using features::bindings::KeyRouter;

}
