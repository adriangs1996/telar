#pragma once

#include <unistd.h>
#include <utility>

namespace telar::runtime {

class FileDescriptor {
public:
  explicit FileDescriptor(int descriptor = -1) noexcept
      : descriptor_(descriptor) {}

  ~FileDescriptor() {
    reset();
  }

  FileDescriptor(const FileDescriptor &) = delete;
  FileDescriptor &operator=(const FileDescriptor &) = delete;

  FileDescriptor(FileDescriptor &&other) noexcept
      : descriptor_(other.release()) {}

  FileDescriptor &operator=(FileDescriptor &&other) noexcept {
    if (this != &other) {
      reset(other.release());
    }

    return *this;
  }

  int get() const noexcept {
    return descriptor_;
  }

  explicit operator bool() const noexcept {
    return descriptor_ >= 0;
  }

  int release() noexcept {
    return std::exchange(descriptor_, -1);
  }

  void reset(int descriptor = -1) noexcept {
    if (descriptor_ >= 0) {
      ::close(descriptor_);
    }

    descriptor_ = descriptor;
  }

private:
  int descriptor_;
};

void setNonblocking(int descriptor);
void setCloseOnExec(int descriptor);

}
