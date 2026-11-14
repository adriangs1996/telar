module telar.clipboard.linux;

import std;
import telar.sys.posix;

namespace telar::clipboard::linux_backend {
  descriptor::descriptor(int value)
      : value_(value) {}

  descriptor::~descriptor() {
    if (value_ >= 0) {
      close(value_);
    }
  }

  int descriptor::get() const {
    return value_;
  }

  std::expected<void, read_error> wait(int fd, short events, deadline expires) {
    for (;;) {
      const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(expires - clock::now()).count();
      if (remaining <= 0) {
        return std::unexpected(read_error::timed_out);
      }

      pollfd event{.fd = fd, .events = events, .revents = 0};
      const auto timeout = static_cast<int>(std::min<decltype(remaining)>(remaining, std::numeric_limits<int>::max()));
      const int result = poll(&event, 1, timeout);
      if (result > 0) {
        if ((event.revents & POLLNVAL) != 0) {
          return std::unexpected(read_error::read_failed);
        }

        return {};
      }

      if (result < 0 && sys::lastError() != EINTR) {
        return std::unexpected(read_error::read_failed);
      }
    }
  }
}
