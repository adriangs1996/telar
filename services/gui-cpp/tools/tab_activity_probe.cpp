#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <cmath>
#include <numbers>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <tuple>
#include <charconv>
#include <cstring>
#include <system_error>
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <cstdio>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.graphics.texture_cache;
import telar.gui.platform.private_file_stamp;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;

constexpr unsigned progress_rgb = 0x72b7ae;
constexpr unsigned error_rgb = 0xf27c7c;
constexpr unsigned pause_rgb = 0xe8c56a;

std::optional<Byte> readPercent() {
  const auto percent = probe::read<Byte>();

  return percent == std::numeric_limits<Byte>::max() ? std::nullopt : std::optional{percent};
}

void selection() {
  SystemAllocator memory;
  GraphicsBudget budget;
  const TabLocation location{.workspace = {.kind = static_cast<WorkspaceLocation::Kind>(probe::read<Byte>()), .id = probe::read<std::uint64_t>()}, .tab_id = probe::read<std::uint64_t>()};
  Tab tab{memory, location};
  const auto selected = probe::read<Byte>() != 0;
  const auto pane_count = probe::read<Byte>();
  for (Byte index = 0; index < pane_count; ++index) {
    tab.layout.add(index + 1, ClientLayoutAxis::horizontal, 1);
  }

  Pane pane{memory, 1, budget};
  const auto present = probe::read<Byte>() != 0;
  pane.progress_state = static_cast<PaneProgressState>(probe::read<Byte>());
  pane.progress_percent = readPercent();
  const auto count = probe::read<Byte>();
  Vector<Agent<SystemAllocator>, SystemAllocator> agents{AllocatorRef<Agent<SystemAllocator>, SystemAllocator>{memory}};
  for (Byte index = 0; index < count; ++index) {
    auto &agent = agents.emplace_back(memory);
    agent.pane_id = probe::read<std::uint64_t>();
    agent.pane_generation = probe::read<std::uint64_t>();
    agent.status = static_cast<AgentStatus>(probe::read<Byte>());
    agent.status_age_s = probe::read<std::uint32_t>();
    agent.location.workspace.kind = static_cast<WorkspaceLocation::Kind>(probe::read<Byte>());
    agent.location.workspace.id = probe::read<std::uint64_t>();
    agent.location.tab_id = probe::read<std::uint64_t>();
  }

  const auto activity = TabActivity::derive(tab, present ? &pane : nullptr, std::span<const Agent<SystemAllocator>>{agents}, selected);
  probe::write(static_cast<Byte>(activity.kind));
  probe::write(activity.width());
  probe::writeText(palette_names[static_cast<std::size_t>(activity.kind == TabActivity::Kind::none ? PaletteRole::text : activity.color)]);
  probe::writeText(palette_names[static_cast<std::size_t>(activity.attention.value_or(PaletteRole::text))]);
}

void writePaint(const RoundedRectanglePaint &paint) {
  const auto fill = paint.shape.style.fill;
  const auto border = paint.shape.style.border;
  const std::array values{paint.origin.x, paint.origin.y, paint.shape.size.x, paint.shape.size.y, paint.shape.style.radius, paint.shape.style.border_width, fill.r, fill.g, fill.b, fill.a, border.r, border.g, border.b, border.a};
  probe::write(values);
}

void ring() {
  const auto area = probe::read<Rect>();
  const auto color = probe::read<Color>();
  const auto fraction = probe::read<float>();
  const auto turns = probe::read<float>();
  std::array<RoundedRectanglePaint, ProgressRing::segments + 2> paints{};
  std::size_t count = 0;
  ProgressRing{.area = area, .color = color, .fraction = fraction, .rotation = turns}.visit([&](RoundedRectanglePaint paint) {
    paints[count++] = paint;
  });
  probe::write(static_cast<std::uint16_t>(count));
  for (const auto &paint : std::span{paints}.first(count)) {
    writePaint(paint);
  }
}

void capsule() {
  const auto area = probe::read<Rect>();
  const auto ratio = probe::read<float>();
  const auto state = static_cast<PaneProgressState>(probe::read<Byte>());
  const auto percent = readPercent();
  const auto timestamp = probe::read<std::uint64_t>();
  auto color = Color::rgb(progress_rgb);
  if (state == PaneProgressState::error) {
    color = Color::rgb(error_rgb);
  } else if (state == PaneProgressState::pause) {
    color = Color::rgb(pause_rgb);
  }

  const auto frame = state == PaneProgressState::indeterminate ? ProgressAnimation::indeterminate<platform::ProgressCosine>(timestamp) : ProgressAnimation::Frame{.fraction = static_cast<float>(percent.value_or(0)) / ProgressSample::maximum_percent};
  constexpr std::size_t extra_shapes = 3;
  std::array<RoundedRectanglePaint, ProgressRing::segments + 2 + extra_shapes> paints{};
  std::size_t count = 0;
  ProgressCapsule{.area = area, .color = color, .ratio = ratio, .state = state, .fraction = frame.fraction, .rotation = frame.turns}.visit([&](RoundedRectanglePaint paint) {
    paints[count++] = paint;
  });
  probe::write(static_cast<std::uint16_t>(count));
  for (const auto &paint : std::span{paints}.first(count)) {
    writePaint(paint);
  }
}

void motion(ProgressMotion &motion) {
  ProgressSample report;
  report.pane_id = probe::read<std::uint64_t>();
  report.attachment = probe::read<std::uint64_t>();
  report.state = static_cast<PaneProgressState>(probe::read<Byte>());
  report.percent = readPercent();
  const auto timestamp = probe::read<std::uint64_t>();
  const auto visible = probe::read<Byte>() != 0;
  if (!visible) {
    motion = {};
    probe::write(0.0F);
    return;
  }

  probe::write(motion.sample(report, timestamp));
}

void indeterminate() {
  const auto timestamp = probe::read<std::uint64_t>();
  const auto frame = ProgressAnimation::indeterminate<platform::ProgressCosine>(timestamp);
  probe::write(frame.fraction);
  probe::write(frame.turns);
}

}

int main() try {
  ProgressMotion progress;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return std::ferror(stdin) == 0 ? 0 : 1;
    }

    switch (operation) {
    case 0:
      selection();
      break;
    case 1:
      ring();
      break;
    case 2:
      motion(progress);
      break;
    case 3:
      indeterminate();
      break;
    case 4:
      capsule();
      break;
    default:
      throw std::invalid_argument{"UnknownTabActivityOperation"};
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
