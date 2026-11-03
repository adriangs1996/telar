#pragma once

#include "clipboard.hpp"
#include <array>
#include <cerrno>
#include <chrono>
#include <climits>
#include <poll.h>
#include <unistd.h>

namespace telar::clipboard::linux_backend {
  using clock = std::chrono::steady_clock;
  using deadline = clock::time_point;
  inline constexpr auto read_timeout = std::chrono::seconds(5);

  struct format {
    const char *target;
    std::string_view mime_type;
  };

  inline constexpr std::array formats = {
      format{"image/png", "image/png"},
      format{"image/jpeg", "image/jpeg"},
      format{"image/tiff", "image/tiff"},
      format{"text/plain;charset=utf-8", "text/plain;charset=utf-8"},
      format{"UTF8_STRING", "text/plain;charset=utf-8"},
      format{"text/plain", "text/plain"},
  };

  class descriptor {
  public:
    explicit descriptor(int value)
        : value_(value) {}

    ~descriptor() {
      if (value_ >= 0) {
        close(value_);
      }
    }

    descriptor(const descriptor &) = delete;
    descriptor &operator=(const descriptor &) = delete;

    int get() const {
      return value_;
    }

  private:
    int value_;
  };

  inline std::expected<void, read_error> wait(int fd, short events, deadline expires) {
    for (;;) {
      const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(expires - clock::now()).count();
      if (remaining <= 0) {
        return std::unexpected(read_error::timed_out);
      }

      pollfd event{.fd = fd, .events = events, .revents = 0};
      const int result = poll(&event, 1, static_cast<int>(remaining > INT_MAX ? INT_MAX : remaining));
      if (result > 0) {
        if ((event.revents & POLLNVAL) != 0) {
          return std::unexpected(read_error::read_failed);
        }

        return {};
      }

      if (result < 0 && errno != EINTR) {
        return std::unexpected(read_error::read_failed);
      }
    }
  }

  std::expected<content, read_error> readWayland(deadline expires);
  std::expected<content, read_error> readX11(deadline expires);
}
