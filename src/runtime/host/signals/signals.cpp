module telar.runtime.host.signals;

import telar.platform.error;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  CompletionSignal::CompletionSignal() {
    ds::Array<int, 2> descriptors{};
    if (::pipe(descriptors.dataMut()) != 0) {
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
    // Each notification writes one byte; a drain reads them in batches.
    constexpr std::size_t drain_bytes = 64;
    ds::Array<std::uint8_t, drain_bytes> bytes{};

    while (::read(reader_.get(), bytes.dataMut(), bytes.size()) > 0) {
    }
  }

  bool CompletionSignal::consume() noexcept {
    std::uint8_t byte = 0;
    auto count = ::read(reader_.get(), &byte, sizeof(byte));

    while (count < 0 && sys::lastError() == EINTR) {
      count = ::read(reader_.get(), &byte, sizeof(byte));
    }

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
