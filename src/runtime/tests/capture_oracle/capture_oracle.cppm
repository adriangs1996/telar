module;
#include <cstddef>
#include <cstdint>
#include <cstring>

export module telar.runtime.tests.capture_oracle;

import std;

export {
struct CaptureOperation {
  const char *bytes;
  std::size_t length;
  std::uint32_t kind;
  std::uint32_t slot;
};

struct CaptureOracleInput {
  const CaptureOperation *operations;
  std::size_t count;
  std::size_t part_limit;
  std::size_t exchange_limit;
  std::size_t total_limit;
  std::size_t fail_allocation;
  std::uint8_t *output;
  std::size_t output_capacity;
  std::uint8_t enabled;
};

struct CaptureOracleResult {
  std::size_t length;
  std::size_t allocation_calls;
  std::size_t retained_allocations;
  std::size_t retained_quota;
  std::uint8_t overflow;
};

class CaptureOracleOutput {
public:
  explicit CaptureOracleOutput(const CaptureOracleInput &input, CaptureOracleResult &result) noexcept : input_(input), result_(result) {}

  void integer(std::uint64_t value) noexcept {
    std::uint8_t bytes[8];
    for (std::size_t index = 0; index < sizeof(value); ++index) {
      bytes[index] = static_cast<std::uint8_t>(value >> (8 * index));
    }
    append(bytes);
  }

  void bytes(std::span<const std::uint8_t> value) noexcept {
    integer(value.size());
    append(value);
  }

  void text(std::string_view value) noexcept {
    bytes({reinterpret_cast<const std::uint8_t *>(value.data()), value.size()});
  }

private:
  void append(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.size() > input_.output_capacity - result_.length) {
      result_.overflow = 1;
      return;
    }
    if (!bytes.empty()) {
      std::memcpy(input_.output + result_.length, bytes.data(), bytes.size());
      result_.length += bytes.size();
    }
  }

  const CaptureOracleInput &input_;
  CaptureOracleResult &result_;
};
}
