module telar.runtime.platform.signals;

import telar.platform.error;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  CompletionSignal::CompletionSignal() {
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

  void CompletionSignal::notify() noexcept {
    const std::uint8_t byte = 1;

    while (::write(writer_.get(), &byte, sizeof(byte)) < 0 && sys::lastError() == EINTR) {
    }
  }

  void CompletionSignal::drain() noexcept {
    ds::Array<std::uint8_t, 64> bytes;

    while (::read(reader_.get(), bytes.dataMut(), bytes.size()) > 0) {
    }
  }

  bool CompletionSignal::consume() noexcept {
    std::uint8_t byte;
    ssize_t count;

    do {
      count = ::read(reader_.get(), &byte, sizeof(byte));
    } while (count < 0 && sys::lastError() == EINTR);

    return count == sizeof(byte);
  }

  int CompletionSignal::descriptor() const noexcept {
    return reader_.get();
  }

  void CancellationSignal::request() noexcept {
    requested_.store(true, std::memory_order_relaxed);
    wake_.notify();
  }

  bool CancellationSignal::requested() const noexcept {
    return requested_.load(std::memory_order_relaxed);
  }

  int CancellationSignal::descriptor() const noexcept {
    return wake_.descriptor();
  }

}
