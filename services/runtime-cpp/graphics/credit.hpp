#pragma once

#include "storage.hpp"

namespace telar::runtime {

class GraphicsCreditBudget {
public:
  bool acquire(std::size_t bytes) noexcept {
    if (bytes > available()) {
      return false;
    }
    used_ += bytes;
    return true;
  }

  void release(std::size_t bytes) noexcept {
    used_ -= bytes;
  }

  std::size_t used() const noexcept {
    return used_;
  }

  std::size_t available() const noexcept {
    return limit - used_;
  }

  static constexpr std::size_t limit = 512 * 1024 * 1024;

private:
  std::size_t used_ = 0;
};

class GraphicsCreditLedger {
public:
  explicit GraphicsCreditLedger(GraphicsCreditBudget &budget) noexcept
      : budget_(budget) {}

  ~GraphicsCreditLedger() {
    budget_.release(graphics_credit_bytes - available_);
  }

  GraphicsCreditLedger(const GraphicsCreditLedger &) = delete;
  GraphicsCreditLedger &operator=(const GraphicsCreditLedger &) = delete;

  bool canReserve(std::size_t bytes) const noexcept {
    return bytes <= available_ && bytes <= budget_.available();
  }

  bool reserve(std::size_t bytes) noexcept {
    if (bytes > available_ || !budget_.acquire(bytes)) {
      return false;
    }
    available_ -= bytes;
    return true;
  }

  bool returnBytes(std::uint64_t bytes) noexcept {
    if (bytes == 0 || bytes > graphics_credit_bytes - available_) {
      return false;
    }
    available_ += bytes;
    budget_.release(bytes);
    return true;
  }

  std::size_t available() const noexcept {
    return available_;
  }

private:
  GraphicsCreditBudget &budget_;
  std::size_t available_ = graphics_credit_bytes;
};

}
