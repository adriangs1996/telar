#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <utility>

namespace telar::gui::platform {

// Owns one Core Foundation reference: the CFRelease that balances the Create or Copy call that
// returned it. Empty when that call returned null.
template <typename Value>
class NativeReference {
public:
  NativeReference() noexcept = default;

  explicit NativeReference(Value value) noexcept
      : value_(value) {}

  ~NativeReference() {
    reset();
  }

  NativeReference(const NativeReference &) = delete;
  NativeReference &operator=(const NativeReference &) = delete;

  NativeReference(NativeReference &&other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}

  NativeReference &operator=(NativeReference &&other) noexcept {
    if (this != &other) {
      reset(std::exchange(other.value_, nullptr));
    }
    return *this;
  }

  [[nodiscard]] Value get() const noexcept {
    return value_;
  }

  explicit operator bool() const noexcept {
    return value_ != nullptr;
  }

  void reset(Value value = nullptr) noexcept {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
    value_ = value;
  }

  // Hands the reference to a caller that releases it.
  [[nodiscard]] Value release() noexcept {
    return std::exchange(value_, nullptr);
  }

private:
  Value value_ = nullptr;
};

}
