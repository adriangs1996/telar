#pragma once

#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct HistoryChoice {
  std::size_t index = 0;
  std::uint64_t revision = 0;

  bool operator==(const HistoryChoice &) const = default;
};

}
