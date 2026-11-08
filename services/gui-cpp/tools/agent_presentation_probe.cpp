#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_io;
import telar.gui.core.metrics;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar::gui;

static_assert(std::endian::native == std::endian::little);

enum class RequestKind : std::uint8_t {
  status,
  geometry,
};

struct StatusRequest {
  std::uint32_t status = 0;
  std::uint32_t reason = 0;
  std::uint32_t seconds = 0;
  std::uint32_t frame = 0;
  std::uint32_t connected = 0;
};

struct GeometryRequest {
  float small_row = 0;
  float title_row = 0;
  float scale = 1;
  Rect bounds;
};

using probe::read;
using probe::write;

void writeText(std::string_view text) {
  write(static_cast<std::uint32_t>(text.size()));
  if (!text.empty() && std::fwrite(text.data(), sizeof(char), text.size(), stdout) != text.size()) {
    throw std::runtime_error{"PresentationWriteFailed"};
  }
}

void status() {
  const auto request = read<StatusRequest>();
  constexpr std::uint32_t maximum_frame = UINT8_MAX;
  if (request.status > static_cast<std::uint32_t>(telar::AgentStatus::done) || request.reason > static_cast<std::uint32_t>(telar::AgentBlockedReason::other) || request.frame > maximum_frame || request.connected > 1) {
    throw std::invalid_argument{"InvalidPresentationRequest"};
  }

  const auto state = static_cast<telar::AgentStatus>(request.status);
  const auto reason = static_cast<telar::AgentBlockedReason>(request.reason);
  using Status = AgentStatusPresentation;
  writeText(Status::word(state, reason));
  writeText(Status::glyph(state, reason));
  writeText(Status::text(state, reason, request.seconds, request.connected != 0).view());
  writeText(Status::age(request.seconds).view());
  writeText(Status::age(request.seconds, true).view());
  writeText(palette_names[static_cast<std::size_t>(Status::color(state))]);
  write(Status::pulse(static_cast<std::uint8_t>(request.frame)));
}

void geometry() {
  const auto request = read<GeometryRequest>();
  const AgentCardGeometry card{.small_row = request.small_row, .title_row = request.title_row, .scale = request.scale};
  const std::array dimensions{card.height(), card.height() + card.px(AgentCardGeometry::spacing), card.px(AgentCardGeometry::horizontal_padding), card.px(AgentCardGeometry::vertical_padding)};
  write(dimensions);
  const std::array rows{card.row(request.bounds, AgentCardGeometry::Row::context), card.row(request.bounds, AgentCardGeometry::Row::title), card.row(request.bounds, AgentCardGeometry::Row::detail)};
  static_assert(sizeof(rows) == sizeof(float) * rows.size() * 4);
  write(rows);
}

}

int main() {
  try {
    RequestKind kind{};
    while (std::fread(&kind, sizeof(kind), 1, stdin) == 1) {
      switch (kind) {
      case RequestKind::status:
        status();
        break;
      case RequestKind::geometry:
        geometry();
        break;
      default:
        throw std::invalid_argument{"UnknownPresentationRequest"};
      }
    }

    return std::feof(stdin) != 0 && std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
