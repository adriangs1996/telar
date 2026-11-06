#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <utility>
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.application.host_effects;

namespace {

using telar::gui::LimitReports;
using telar::SystemAllocator;
namespace probe = telar::gui::probe;

enum class Operation : std::uint8_t {
  reset,
  record,
  take,
  restore,
};

void writeOptional(std::optional<std::int64_t> value) {
  probe::write(static_cast<std::uint8_t>(value.has_value()));
  probe::write(value.value_or(0));
}

void write(const LimitReports &reports) {
  probe::write(static_cast<std::uint32_t>(reports.rows().size()));
  probe::write(reports.evicted());
  for (const auto &row : reports.rows()) {
    probe::writeText(row.name.view());
    probe::writeText(row.noun.view());
    probe::writeText(row.route.view());
    probe::write(row.value);
    probe::write(static_cast<std::uint8_t>(row.requested.has_value()));
    probe::write(row.requested.value_or(0));
    probe::write(row.hits);
    probe::write(row.unreported);
    probe::write(row.last_ms);
    writeOptional(row.shown_ms);
    writeOptional(row.reported_ms);
    probe::writeText(LimitReports::describe(row.reach(), row.hits).view());
  }
}

void execute(LimitReports &reports, Operation operation, SystemAllocator &memory) {
  std::uint32_t slot = 0;
  bool show = false;
  std::optional<std::uint32_t> hits;
  switch (operation) {
  case Operation::reset:
    reports = {};
    break;
  case Operation::record: {
    const auto name = probe::readText(memory);
    const auto noun = probe::readText(memory);
    const auto route = probe::readText(memory);
    const auto value = probe::read<std::uint64_t>();
    const auto has_requested = probe::read<std::uint8_t>() != 0;
    const auto requested = probe::read<std::uint64_t>();
    const auto awake_ms = probe::read<std::int64_t>();
    const auto real_ms = probe::read<std::int64_t>();
    const auto count = probe::read<std::uint32_t>();
    const auto result = reports.record({.name = name, .noun = noun, .value = value, .requested = has_requested ? std::optional{requested} : std::nullopt, .route = route}, {.awake_ms = awake_ms, .real_ms = real_ms}, count);
    slot = static_cast<std::uint32_t>(result.slot.value);
    show = result.show;
    break;
  }
  case Operation::take:
    slot = probe::read<std::uint32_t>();
    hits = reports.takeReport({slot}, probe::read<std::int64_t>());
    break;
  case Operation::restore:
    slot = probe::read<std::uint32_t>();
    reports.restoreReport({slot}, probe::read<std::uint32_t>());
    break;
  default:
    throw std::invalid_argument{"Unknown limit report operation"};
  }

  probe::write(slot);
  probe::write(static_cast<std::uint8_t>(show));
  probe::write(static_cast<std::uint8_t>(hits.has_value()));
  probe::write(hits.value_or(0));
  write(reports);
}

}

int main() {
  try {
    LimitReports reports;
    SystemAllocator memory;
    for (auto value = std::getchar(); value != EOF; value = std::getchar()) {
      execute(reports, static_cast<Operation>(value), memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
