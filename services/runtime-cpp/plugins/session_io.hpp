#pragma once

#include "../memory/sensitive_text.hpp"
#include "../platform/cancellation_signal.hpp"
#include "../platform/pipe_process.hpp"
#include "limits.hpp"
#include <algorithm>
#include <array>
#include <climits>
#include <poll.h>

namespace telar::runtime::plugins {

class SessionIo {
public:
  explicit SessionIo(PipeProcess &process, const CancellationSignal &cancellation) noexcept
      : process_(process), cancellation_(cancellation) {}

  void deadline(std::chrono::milliseconds timeout) noexcept { deadline_ = Clock::now() + timeout; }

  bool active() const noexcept {
    if (cancellation_.requested()) {
      errno = ECANCELED;
      return false;
    }
    if (deadline_ != Clock::time_point::max() && Clock::now() >= deadline_) {
      errno = ETIMEDOUT;
      return false;
    }
    return true;
  }

  bool ready(int descriptor, short events) noexcept {
    for (;;) {
      std::array watches{
          pollfd{descriptor, events, 0},
          pollfd{process_.error(), POLLIN, 0},
          pollfd{cancellation_.descriptor(), POLLIN, 0},
      };
      const auto timeout = remainingMilliseconds();
      if (timeout == 0) {
        errno = ETIMEDOUT;
        return false;
      }
      const auto count = ::poll(watches.data(), watches.size(), timeout);
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        if (count == 0) {
          errno = ETIMEDOUT;
        }
        return false;
      }
      if (watches[2].revents != 0) {
        errno = ECANCELED;
        return false;
      }

      if (watches[1].revents != 0) {
        drainError();
      }
      if (watches[0].revents != 0) {
        return true;
      }
    }
  }

  void drainError() noexcept {
    std::array<char, error_chunk_bytes> bytes;
    std::size_t drained = 0;
    while (process_.error() >= 0 && drained < maximum_error_drain_bytes) {
      const auto count = ::read(process_.error(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
          process_.closeError();
        }
        return;
      }

      const auto received = static_cast<std::size_t>(count);
      const auto retained = std::min(received, Limits::stderr_bytes - error_.view().size());
      error_.append({bytes.data(), retained});
      drained += received;
    }
  }

  std::string_view retainedError() const noexcept { return error_.view(); }

private:
  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t error_chunk_bytes = 1024;
  static constexpr std::size_t maximum_error_drain_bytes = 64 * 1024;

  int remainingMilliseconds() const noexcept {
    if (deadline_ == Clock::time_point::max()) {
      return -1;
    }
    const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(deadline_ - Clock::now()).count();
    return static_cast<int>(std::clamp<decltype(remaining)>(remaining, 0, INT_MAX));
  }

  PipeProcess &process_;
  const CancellationSignal &cancellation_;
  Clock::time_point deadline_ = Clock::time_point::max();
  SensitiveText<Limits::stderr_bytes> error_;
};

}
