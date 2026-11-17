// The plugins as ui runs them: the catalog of a generation's packages and the pages a client
// reads of it, the overrides a client sets, and the run of an action with the effects it
// returns. ui reads the packages and the trust store and runs a plugin on its workers, so these
// are types ui holds, not use cases of a session.
export module telar.gui.application:plugins;

import telar.gui.features.plugins;

export namespace telar::gui::application::plugins {

  using features::plugins::PluginCatalog;
  using features::plugins::PluginEffects;
  using features::plugins::PluginInvocation;
  using features::plugins::PluginOverrides;
  using features::plugins::PluginPage;
  using features::plugins::PluginQuery;

}
