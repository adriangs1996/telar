#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.tools.probe_io;
import telar.gui.tools.probe_text;
import telar.gui.core.metrics;
import telar.gui.presentation.history_inspection;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  duration,
  age,
  local_day,
  clock,
  day_label,
  date_label,
  status,
  age_at,
};

void frame(Operation operation) {
  const auto value = probe::read<std::int64_t>();
  switch (operation) {
  case Operation::duration:
    probe::writeText(HistoryLabels::duration(value).view());
    break;
  case Operation::age:
    probe::writeText(HistoryLabels::age(value).view());
    break;
  case Operation::local_day:
    probe::write(HistoryLabels::localDay(value, probe::read<std::int16_t>()));
    break;
  case Operation::clock:
    probe::writeText(HistoryLabels::clock(value, probe::read<std::int16_t>()).view());
    break;
  case Operation::day_label:
    probe::writeText(HistoryLabels::dayLabel(value, probe::read<std::int64_t>()).view());
    break;
  case Operation::date_label: {
    const auto now = probe::read<std::int64_t>();
    const auto offset = probe::read<std::int16_t>();
    probe::writeText(HistoryLabels::dateLabel(value, {.now_ms = now, .utc_offset_min = offset}).view());
    break;
  }
  case Operation::status: {
    const auto has_exit = probe::read<std::uint8_t>() != 0;
    const auto code = probe::read<std::int32_t>();
    const auto status = HistoryLabels::status(static_cast<telar::HistoryStatus>(value), has_exit ? std::optional{code} : std::nullopt);
    probe::writeText(status.glyph);
    probe::writeText(palette_names[static_cast<std::size_t>(status.color)]);
    break;
  }
  case Operation::age_at:
    probe::writeText(HistoryLabels::ageAt(value, {.now_ms = probe::read<std::int64_t>()}).view());
    break;
  default:
    throw std::invalid_argument{"UnknownHistoryLabelOperation"};
  }
}

}

int main() {
  try {
    while (true) {
      const auto operation = std::getchar();
      if (operation == EOF) {
        return 0;
      }

      frame(static_cast<Operation>(operation));
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
