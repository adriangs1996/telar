#include "presentation/tab_motion_frame.hpp"
#include "presentation/tab_motions.hpp"
#include "probe_io.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <optional>

int main() try {
  using namespace telar;
  using namespace telar::gui;
  TabMotions motions;
  TabMotionFrame timing;
  std::uint64_t now_ns = 0;
  for (auto operation = std::getc(stdin); operation != EOF; operation = std::getc(stdin)) {
    const auto present = probe::read<std::uint8_t>() != 0;
    const WorkspaceLocation workspace{.kind = probe::read<WorkspaceLocation::Kind>(), .id = probe::read<std::uint64_t>()};
    now_ns = std::max(now_ns, probe::read<std::uint64_t>());
    const auto interval_ns = probe::read<std::uint64_t>();
    const auto count = probe::read<std::uint16_t>();
    timing.begin(now_ns);
    timing.interval_ns = interval_ns;
    motions.begin(present ? std::optional{workspace} : std::nullopt);
    for (std::uint16_t index = 0; index < count; ++index) {
      const TabMotionSlot slot{.id = probe::read<std::uint64_t>(), .bounds = {.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()}, .immediate = probe::read<std::uint8_t>() != 0};
      const auto value = motions.place(slot, timing);
      probe::write(value.x);
      probe::write(value.y);
      probe::write(value.width);
      probe::write(value.height);
    }
    motions.finish();
    const auto deadline = timing.deadline_ns;
    probe::write(static_cast<std::uint16_t>(motions.size()));
    probe::write(static_cast<std::uint8_t>(deadline.has_value()));
    probe::write(deadline.value_or(0));
  }
  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';
  return 1;
}
