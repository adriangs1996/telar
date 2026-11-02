#pragma once

#include "../memory/erasing_allocator.hpp"
#include "../memory/sensitive_allocation.hpp"
#include "../text/ascii.hpp"
#include <array>
#include <optional>

namespace telar::runtime {

template <Allocator Memory>
class HttpFields {
  using Secure = ErasingAllocator<Memory>;

public:
  class Field {
  public:
    Field(Memory &memory, std::string_view name, std::string_view value) : storage_(memory, name.size() + value.size()), name_bytes_(name.size()) {
      auto bytes = storage_.bytes();
      std::ranges::copy(name, bytes.begin());
      std::ranges::copy(value, bytes.begin() + name.size());
    }

    auto name() const noexcept -> std::string_view { return text().substr(0, name_bytes_); }
    auto value() const noexcept -> std::string_view { return text().substr(name_bytes_); }

  private:
    auto text() const noexcept -> std::string_view {
      const auto bytes = storage_.bytes();
      return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    }

    SensitiveAllocation<Memory> storage_;
    std::size_t name_bytes_;
  };

  explicit HttpFields(Memory &memory) : upstream_(memory), memory_(memory), fields_(AllocatorRef<Field, Secure>{memory_}) {}
  HttpFields(const HttpFields &) = delete;
  HttpFields &operator=(const HttpFields &) = delete;

  void append(std::string_view name, std::string_view value) {
    validate(name, value);
    if (fields_.size() == maximum_fields || name.size() + value.size() + line_overhead > maximum_bytes - bytes_) {
      throw std::length_error{"HTTP fields exceed their limit"};
    }

    fields_.emplace_back(upstream_, name, value);
    bytes_ += name.size() + value.size() + line_overhead;
  }

  void set(std::string_view name, std::string_view value) {
    validate(name, value);
    const auto previous = std::ranges::find_if(fields_, [&](const Field &field) { return asciiEqualIgnoreCase(field.name(), name); });
    if (previous == fields_.end()) { append(name, value); return; }
    const auto old_bytes = previous->name().size() + previous->value().size();
    if (name.size() + value.size() > maximum_bytes - (bytes_ - old_bytes)) { throw std::length_error{"HTTP fields exceed their limit"}; }

    Field replacement{upstream_, name, value};
    bytes_ = bytes_ - old_bytes + name.size() + value.size();
    *previous = std::move(replacement);
    for (auto cursor = std::next(previous); cursor != fields_.end();) {
      if (asciiEqualIgnoreCase(cursor->name(), previous->name())) {
        bytes_ -= cursor->name().size() + cursor->value().size() + line_overhead;
        cursor = fields_.erase(cursor);
      } else { ++cursor; }
    }
  }

  void remove(std::string_view name) noexcept {
    std::array<bool, maximum_fields> matching{};
    for (std::size_t index = 0; index < fields_.size(); ++index) {
      matching[index] = asciiEqualIgnoreCase(fields_[index].name(), name);
    }
    for (auto index = fields_.size(); index != 0; --index) {
      if (matching[index - 1]) {
        const auto cursor = fields_.begin() + index - 1;
        bytes_ -= cursor->name().size() + cursor->value().size() + line_overhead;
        fields_.erase(cursor);
      }
    }
  }

  auto get(std::string_view name) const noexcept -> std::optional<std::string_view> {
    for (const auto &field : fields_) {
      if (asciiEqualIgnoreCase(field.name(), name)) { return field.value(); }
    }
    return std::nullopt;
  }

  auto fields() const noexcept -> std::span<const Field> { return fields_; }
  auto bytes() const noexcept -> std::size_t { return bytes_; }
  void clear() noexcept { fields_.clear(); bytes_ = 0; }

  static bool token(std::string_view text) noexcept {
    if (text.empty()) { return false; }
    return std::ranges::all_of(text, [](unsigned char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || std::string_view{"!#$%&'*+-.^_`|~"}.find(byte) != std::string_view::npos; });
  }

  static void validate(std::string_view name, std::string_view value) {
    if (!token(name) || name.size() > maximum_bytes || value.size() > maximum_bytes || std::ranges::any_of(value, [](unsigned char byte) { return (byte < 32 && byte != '\t') || byte == 127; })) {
      throw std::invalid_argument{"Invalid HTTP field"};
    }
  }

  static constexpr std::size_t maximum_fields = 256;
  static constexpr std::size_t maximum_bytes = 64 * 1024;

private:
  static constexpr std::size_t line_overhead = 4;
  Memory &upstream_;
  Secure memory_;
  Vector<Field, Secure> fields_;
  std::size_t bytes_ = 0;
};

}
