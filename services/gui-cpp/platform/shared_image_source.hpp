#pragma once

#include "telar_platform/file_descriptor.hpp"
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui::platform {

class SharedImageSource {
public:
  explicit SharedImageSource(std::string_view name);
  ~SharedImageSource() = default;
  SharedImageSource(const SharedImageSource &) = delete;
  SharedImageSource &operator=(const SharedImageSource &) = delete;
  SharedImageSource(SharedImageSource &&) noexcept = default;
  SharedImageSource &operator=(SharedImageSource &&) noexcept = default;

  [[nodiscard]] bool read(std::span<std::uint8_t> destination) const noexcept;

private:
  runtime::FileDescriptor descriptor_;
};

}
