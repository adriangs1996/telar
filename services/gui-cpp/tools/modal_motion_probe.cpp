#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstdio>

import std;
import telar.gui.tools.probe_io;
import telar.gui.presentation.suggestion_labels;

int main() try {
  using namespace telar::gui;
  ModalMotion motion;
  std::uint64_t now = 0;
  for (auto incoming = std::getc(stdin); incoming != EOF; incoming = std::getc(stdin)) {
    if (incoming == 0) {
      motion = {};
      now = 0;

      continue;
    }

    const bool has_generation = probe::read<std::uint8_t>() != 0;
    const auto generation = probe::read<std::uint64_t>();
    const bool animated = probe::read<std::uint8_t>() != 0;
    now = std::max(now, probe::read<std::uint64_t>());
    const auto interval = probe::read<std::uint64_t>();
    const auto reveal = motion.sample(has_generation ? std::optional{generation} : std::nullopt, animated ? std::optional{now} : std::nullopt);
    const auto deadline = animated ? motion.deadline(now, interval) : std::nullopt;
    probe::write(reveal);
    probe::write(static_cast<std::uint8_t>(deadline.has_value()));
    probe::write(deadline.value_or(0));
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
