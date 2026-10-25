#pragma once

#include "stream_ids.hpp"

namespace telar::runtime {

class Http2StreamTracker {
public:
  static constexpr std::size_t capacity = 128;

  struct Response {
    std::uint32_t stream = 0;
    std::uint16_t status = 0;
    bool event_stream = false;
  };

  bool startRequest(std::uint32_t stream) noexcept { return requests_.start(stream); }
  void finishRequest(std::uint32_t stream) noexcept { requests_.finish(stream); }
  bool requestsFull() const noexcept { return requests_.full(); }

  bool setResponse(Response response) noexcept {
    if (response.stream == 0) {
      return false;
    }

    Response *available = nullptr;
    for (auto &entry : responses_) {
      if (entry.stream == response.stream) {
        entry = response;
        return true;
      }
      if (entry.stream == 0 && available == nullptr) {
        available = &entry;
      }
    }

    if (available == nullptr) {
      return false;
    }
    *available = response;
    ++response_count_;
    return true;
  }

  Response response(std::uint32_t stream) const noexcept {
    for (const auto &entry : responses_) {
      if (entry.stream == stream) {
        return entry;
      }
    }
    return {};
  }

  void finishResponse(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return;
    }
    for (auto &entry : responses_) {
      if (entry.stream == stream) {
        entry = {};
        --response_count_;
        return;
      }
    }
  }

  bool hasResponses() const noexcept { return response_count_ != 0; }

private:
  Http2StreamIds<capacity> requests_;
  std::array<Response, capacity> responses_{};
  std::size_t response_count_ = 0;
};

}
