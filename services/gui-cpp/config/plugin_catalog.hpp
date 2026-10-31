#pragma once

#include "plugins/package.hpp"
#include "plugins/specifications.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class PluginCatalog {
public:
  explicit PluginCatalog(std::uint64_t generation, std::span<const runtime::plugins::ConfiguredPlugin> specifications, std::span<const runtime::plugins::Package> packages) noexcept
      : generation_(generation),
        specifications_(specifications),
        packages_(packages) {}

  [[nodiscard]] std::uint64_t generation() const noexcept {
    return generation_;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return specifications_.size();
  }

  [[nodiscard]] const runtime::plugins::ConfiguredPlugin &specification(std::size_t index) const {
    if (index >= size()) {
      throw std::invalid_argument{"PluginNotConfigured"};
    }

    return specifications_[index];
  }

  [[nodiscard]] const runtime::plugins::Package *package(std::size_t index) const noexcept {
    if (index >= size() || !specifications_[index].enabled) {
      return nullptr;
    }

    std::size_t loaded = 0;
    for (const auto &specification : specifications_.first(index)) {
      loaded += static_cast<std::size_t>(specification.enabled);
    }

    return loaded < packages_.size() ? &packages_[loaded] : nullptr;
  }

  [[nodiscard]] std::size_t find(std::string_view name) const {
    for (std::size_t index = 0; index < size(); ++index) {
      if (specifications_[index].path.view() == name) {
        return index;
      }

      if (const auto *loaded = package(index); loaded != nullptr && loaded->manifest.id.view() == name) {
        return index;
      }
    }

    throw std::invalid_argument{"PluginNotConfigured"};
  }

  void validateGeneration(std::uint64_t requested) const {
    if (requested != 0 && requested != generation_) {
      throw std::invalid_argument{"StaleConfiguration"};
    }
  }

private:
  std::uint64_t generation_;
  std::span<const runtime::plugins::ConfiguredPlugin> specifications_;
  std::span<const runtime::plugins::Package> packages_;
};

}
