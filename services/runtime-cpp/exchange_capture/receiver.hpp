#pragma once

#include "../platform/thread_name.hpp"

#include "producer.hpp"
#include <pthread.h>

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class CaptureReceiver {
public:
  struct Request {
    bool decode;
  };

  using Result = std::optional<typename CaptureProducer<Memory>::Half>;

  explicit CaptureReceiver(CaptureProducer<Memory> &producer) noexcept : producer_(producer) {}

  Result observe(const Request &request) noexcept {
    if (!named_) {
      setThreadName("telar.capture");
      named_ = true;
    }

    auto half = producer_.receive();
    if (half && request.decode) {
      producer_.decodeBody(**half);
    }
    return half;
  }

  void stop() noexcept { producer_.close(); }

private:
  CaptureProducer<Memory> &producer_;
  bool named_ = false;
};

}
