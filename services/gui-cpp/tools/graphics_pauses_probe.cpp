#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include <concepts>
#include <utility>
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>



import telar.gui.graphics.pauses;

namespace {

using telar::gui::GraphicsPauses;
namespace probe = telar::gui::probe;

enum class Operation : std::uint8_t {
  reset,
  pause,
  due,
  focus,
  snapshot,
  close,
};

struct Effects {
  std::array<std::uint64_t, GraphicsPauses::capacity * 2> requests{};
  std::array<std::uint64_t, GraphicsPauses::capacity> notices{};
  std::uint32_t request_count = 0;
  std::uint32_t notice_count = 0;

  void request(std::uint64_t pane_id) {
    requests.at(request_count++) = pane_id;
  }

  void notice(std::uint64_t pane_id) {
    notices.at(notice_count++) = pane_id;
  }

  void write() const {
    probe::write(request_count);
    for (std::uint32_t index = 0; index < request_count; ++index) {
      probe::write(requests[index]);
    }

    probe::write(notice_count);
    for (std::uint32_t index = 0; index < notice_count; ++index) {
      probe::write(notices[index]);
    }
  }
};

void write(const GraphicsPauses &pauses, const Effects &effects) {
  effects.write();
  const auto deadline = pauses.nextDeadline();
  probe::write(static_cast<std::uint8_t>(deadline.has_value()));
  probe::write(deadline.value_or(0));
  probe::write(static_cast<std::uint32_t>(pauses.rows().size()));
  for (const auto &row : pauses.rows()) {
    probe::write(row.pane_id);
    probe::write(row.resyncs);
    probe::write(row.since_ns);
    probe::write(row.due_ns);
    probe::write(row.backoff);
    probe::write(static_cast<std::uint8_t>(row.waiting));
    probe::write(static_cast<std::uint8_t>(row.snapshot_begun));
    probe::write(static_cast<std::uint8_t>(row.resumed_ns.has_value()));
    probe::write(row.resumed_ns.value_or(0));
  }
}

void execute(Operation operation, GraphicsPauses &pauses, std::uint64_t &closed) {
  Effects effects;
  const auto request = [&](std::uint64_t pane_id) {
    effects.request(pane_id);
  };
  const auto notice = [&](std::uint64_t pane_id) {
    effects.notice(pane_id);
  };
  switch (operation) {
  case Operation::reset:
    pauses.reset();
    closed = 0;
    break;
  case Operation::pause: {
    const auto pane_id = probe::read<std::uint64_t>();
    const auto now_ns = probe::read<std::uint64_t>();
    if (pane_id != closed) {
      pauses.pause(pane_id, now_ns, request, notice);
    }
    break;
  }
  case Operation::due:
    pauses.resumeDue(probe::read<std::uint64_t>(), request);
    break;
  case Operation::focus: {
    const auto pane_id = probe::read<std::uint64_t>();
    pauses.focus({.pane_id = pane_id, .now_ns = probe::read<std::uint64_t>()}, request);
    break;
  }
  case Operation::snapshot: {
    const auto pane_id = probe::read<std::uint64_t>();
    const auto phase = probe::read<std::uint8_t>();
    pauses.snapshotApplied(pane_id, static_cast<telar::SnapshotPhase>(phase), probe::read<std::uint64_t>());
    break;
  }
  case Operation::close:
    closed = probe::read<std::uint64_t>();
    pauses.forgetClosed([closed](std::uint64_t pane_id) {
      return pane_id != closed;
    });
    break;
  default:
    throw std::invalid_argument{"Unknown graphics pause operation"};
  }

  write(pauses, effects);
}

}

int main() {
  try {
    GraphicsPauses pauses;
    std::uint64_t closed = 0;
    for (auto value = std::getchar(); value != EOF; value = std::getchar()) {
      execute(static_cast<Operation>(value), pauses, closed);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
