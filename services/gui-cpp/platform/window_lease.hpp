#pragma once

#include <array>
#include <climits>
#include <cstdint>
#include <string_view>

namespace telar::gui::platform {

class WindowLease {
public:
  static constexpr unsigned maximum_windows = 64;

  explicit WindowLease(std::string_view endpoint);
  ~WindowLease();
  WindowLease(const WindowLease &) = delete;
  WindowLease &operator=(const WindowLease &) = delete;
  WindowLease(WindowLease &&) = delete;
  WindowLease &operator=(WindowLease &&) = delete;

  [[nodiscard]] unsigned slot() const noexcept;
  [[nodiscard]] std::string_view endpoint() const noexcept;

private:
  std::array<char, PATH_MAX> canonical_endpoint_{};
  std::size_t endpoint_length_ = 0;
  unsigned slot_ = 0;
  int descriptor_ = -1;
};

}
