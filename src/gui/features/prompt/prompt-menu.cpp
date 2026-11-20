module telar.gui.features.prompt;

import telar.tbc;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  Menu::Menu(tbc::view<Memory&, tbc::lt::a> memory)
      : choices(memory),
        requests(memory),
        label(memory),
        all(memory) {}

}
