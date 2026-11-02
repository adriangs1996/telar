#pragma once

#include "plugins/specifications.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class PluginOverrides {
public:
  void set(const runtime::plugins::ConfiguredPlugin &specification, std::optional<std::uint64_t> identity) {
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == specification.path.view()) {
        entry.specification = specification;
        if (identity) {
          entry.identity = identity;
        }

        return;
      }
    }

    if (count_ == entries_.size()) {
      throw std::length_error{"TooManyPluginOverrides"};
    }

    entries_[count_] = {.specification = specification, .identity = identity};
    ++count_;
  }

  [[nodiscard]] std::optional<bool> requested(std::string_view path) const noexcept {
    for (const auto &entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == path) {
        return entry.specification.enabled;
      }
    }

    return std::nullopt;
  }

  void apply(runtime::plugins::Specifications &specifications) const noexcept {
    for (auto &specification : std::span{specifications.entries}.first(specifications.count)) {
      if (const auto enabled = requested(specification.path.view())) {
        specification.enabled = *enabled;
      }
    }
  }

  [[nodiscard]] bool disabled(std::uint64_t identity, std::span<const runtime::plugins::ConfiguredPlugin> specifications) const noexcept {
    for (const auto &entry : std::span{entries_}.first(count_)) {
      if (entry.specification.enabled || entry.identity != identity) {
        continue;
      }

      for (const auto &specification : specifications) {
        if (!specification.enabled && specification.path.view() == entry.specification.path.view()) {
          return true;
        }
      }
    }

    return false;
  }

private:
  struct Entry {
    runtime::plugins::ConfiguredPlugin specification;
    std::optional<std::uint64_t> identity;
  };

  std::array<Entry, runtime::plugins::PackageLimits::configured> entries_{};
  std::size_t count_ = 0;
};

}
