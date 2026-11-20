module telar.gui.features.prompt;

import telar.tbc;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  Menu::Menu(tbc::mut_a<Memory> memory)
      : choices(memory),
        requests(memory),
        label(memory),
        all(memory) {}

}
