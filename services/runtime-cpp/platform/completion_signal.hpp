#pragma once

#include "error.hpp"
#include "file_descriptor.hpp"
#include <array>
#include <cstdint>

namespace telar::runtime {

class CompletionSignal {
public:
  CompletionSignal() {
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

  void notify() noexcept {
    const std::uint8_t byte = 1;
    while (::write(writer_.get(), &byte, sizeof(byte)) < 0 && errno == EINTR) {
    }
  }

  void drain() noexcept {
    std::array<std::uint8_t, 64> bytes;
    while (::read(reader_.get(), bytes.data(), bytes.size()) > 0) {
    }
  }

  bool consume() noexcept {
    std::uint8_t byte;
    ssize_t count;
    do {
      count = ::read(reader_.get(), &byte, sizeof(byte));
    } while (count < 0 && errno == EINTR);
    return count == sizeof(byte);
  }

  int descriptor() const noexcept {
    return reader_.get();
  }

private:
  FileDescriptor reader_;
  FileDescriptor writer_;
};

}
