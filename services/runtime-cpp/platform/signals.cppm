module;
#include "tbc/view.hpp"

#include <unistd.h>
#include <cerrno>
#include <cstdint>

export module telar.runtime.platform.signals;

import std;

import telar.platform;
import telar.platform.primitives;

// Interface: platform/completion_signal.cppm
export {
namespace telar::runtime {

// A pipe one thread notifies and another drains: both ends share it.
class TBC_SHARED CompletionSignal {
public:
  inline CompletionSignal() {
    int descriptors[2];
    if (::pipe(descriptors) != 0) {
      throw SystemError{"Create completion pipe"};
    }
    reader_ = FileDescriptor{descriptors[0]};
    writer_ = FileDescriptor{descriptors[1]};
    setCloseOnExec(reader_.get());
    setCloseOnExec(writer_.get());
    setNonblocking(reader_.get());
    setNonblocking(writer_.get());
  }

  inline void notify() noexcept {
    const std::uint8_t byte = 1;
    while (::write(writer_.get(), &byte, sizeof(byte)) < 0 && errno == EINTR) {
    }
  }

  inline void drain() noexcept {
    std::array<std::uint8_t, 64> bytes;
    while (::read(reader_.get(), bytes.data(), bytes.size()) > 0) {
    }
  }

  inline bool consume() noexcept {
    std::uint8_t byte;
    ssize_t count;
    do {
      count = ::read(reader_.get(), &byte, sizeof(byte));
    } while (count < 0 && errno == EINTR);
    return count == sizeof(byte);
  }

  inline int descriptor() const noexcept {
    return reader_.get();
  }

private:
  FileDescriptor reader_;
  FileDescriptor writer_;
};

}
}

// Interface: platform/cancellation_signal.cppm
export {
namespace telar::runtime {

// Any thread may request cancellation and any may observe it: the flag is atomic and the wake signal
// is shared, so a reference to it stays valid whatever is done through it.
class TBC_SHARED CancellationSignal {
public:
  inline void request() noexcept {
    requested_.store(true, std::memory_order_relaxed);
    wake_.notify();
  }

  inline bool requested() const noexcept { return requested_.load(std::memory_order_relaxed); }
  inline int descriptor() const noexcept { return wake_.descriptor(); }

private:
  CompletionSignal wake_;
  std::atomic<bool> requested_{false};
};

}
}
