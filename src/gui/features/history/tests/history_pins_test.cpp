#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.gui.features.history;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui::features::history;

  // Pins read newest first; pinning one again unpins it.
  void pinsToggleNewestFirst() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    HistoryPins pins{adapted};

    check(pins.toggle("make") && pins.toggle("git push"), "commands are pinned");
    check(pins.count() == 2 && pins.at(0) == "git push" && pins.at(1) == "make", "the newest pin comes first");
    check(!pins.toggle("make") && pins.count() == 1 && !pins.pinned("make") && pins.pinned("git push"), "pinning again unpins");
  }

  // What the file keeps reads back as the same pins, multi-line commands and backslashes whole.
  void pinsSurviveTheirFile() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    HistoryPins pins{adapted};
    HistoryPins restored{adapted};
    ds::String<telar::Memory> file{adapted};

    static_cast<void>(pins.toggle("for f in *; do\n  echo \"$f\"\ndone"));
    static_cast<void>(pins.toggle("printf 'a\\nb'"));
    pins.write(file);
    restored.read(file);
    check(restored.count() == 2 && restored.at(0) == "printf 'a\\nb'" && restored.at(1) == "for f in *; do\n  echo \"$f\"\ndone", "the pins read back as they were written");
  }

  // A file edited by hand keeps the pins it can, once each.
  void pinsReadOnlyWhatFits() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    HistoryPins pins{adapted};
    const std::string long_line(HistoryPins::maximum_command_bytes + 1, 'x');

    pins.read("ls\n\nls\n" + long_line + "\ncargo test");
    check(pins.count() == 2 && pins.at(0) == "cargo test" && pins.at(1) == "ls", "empty, repeated and oversized lines are left out");

    bool refused = false;

    try {
      static_cast<void>(pins.toggle(long_line));
    } catch (const std::length_error&) {
      refused = true;
    }

    check(refused, "a command past the bound is not pinned");
  }

  const telar::testing::Case case_pins_toggle_newest_first{"history_pins.pins_toggle_newest_first", pinsToggleNewestFirst};
  const telar::testing::Case case_pins_survive_their_file{"history_pins.pins_survive_their_file", pinsSurviveTheirFile};
  const telar::testing::Case case_pins_read_only_what_fits{"history_pins.pins_read_only_what_fits", pinsReadOnlyWhatFits};

}
