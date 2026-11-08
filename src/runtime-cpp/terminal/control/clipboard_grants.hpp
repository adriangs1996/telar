#pragma once

#include "telar_platform/random_bytes.hpp"
#include "clipboard_metadata.hpp"
#include <algorithm>
#include <cstdlib>

namespace telar::runtime::control {

struct ClipboardRoute {
  std::uint64_t client = 0;
  std::uint64_t generation = 0;

  bool operator==(const ClipboardRoute &) const = default;
};

class ClipboardGrants {
public:
  static constexpr std::size_t capacity = 32;
  static constexpr std::size_t password_length = 22;

  void grant(std::string_view password, ClipboardRoute route, bool write, bool once) {
    if (password.empty() || password.size() > ClipboardMetadata::maximum_password) {
      return;
    }
    Entry *entry = nullptr;
    for (auto &candidate : std::span{entries_}.first(count_)) {
      if (candidate.route == route && equal(candidate.password.view(), password)) {
        entry = &candidate;
        entry->once &= once;
        break;
      }
    }
    if (entry == nullptr) {
      if (count_ == entries_.size()) {
        std::move(entries_.begin() + 1, entries_.end(), entries_.begin());
        --count_;
      }
      entry = &entries_[count_++];
      entry->password.assign(password);
      entry->route = route;
      entry->read = false;
      entry->write = false;
      entry->once = once;
    }
    if (write) {
      entry->write = true;
    } else {
      entry->read = true;
    }
  }

  std::optional<ClipboardRoute> use(std::string_view password, bool write) {
    std::optional<std::size_t> matching;
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &entry = entries_[index];
      if (!equal(entry.password.view(), password)) {
        continue;
      }
      matching = index;
      if (write ? entry.write : entry.read) {
        break;
      }
    }
    if (!matching) {
      return std::nullopt;
    }
    const auto index = *matching;
    const auto &entry = entries_[index];
    const bool permitted = write ? entry.write : entry.read;
    const auto route = entry.route;
    if (entry.once) {
      std::move(entries_.begin() + index + 1, entries_.begin() + count_, entries_.begin() + index);
      --count_;
    }
    return permitted ? std::optional{route} : std::nullopt;
  }

  void retain(std::span<const ClipboardRoute> routes) noexcept {
    std::size_t kept = 0;
    for (std::size_t index = 0; index < count_; ++index) {
      if (std::find(routes.begin(), routes.end(), entries_[index].route) != routes.end()) {
        if (kept != index) {
          entries_[kept] = entries_[index];
        }
        ++kept;
      }
    }
    count_ = kept;
  }

  void clear() noexcept {
    count_ = 0;
  }

  static FixedText<password_length> password() {
    constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    static_assert(alphabet.size() == 64);
    std::array<std::uint8_t, password_length> random;
    randomBytes(random.data(), random.size());
    std::array<char, password_length> output;
    for (std::size_t index = 0; index < output.size(); ++index) {
      output[index] = alphabet[random[index] & (alphabet.size() - 1)];
    }
    FixedText<password_length> result;
    result.assign({output.data(), output.size()});
    return result;
  }

private:
  struct Entry {
    FixedText<ClipboardMetadata::maximum_password> password;
    ClipboardRoute route;
    bool read = false;
    bool write = false;
    bool once = false;
  };

  static bool equal(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }
    unsigned difference = 0;
    for (std::size_t index = 0; index < left.size(); ++index) {
      difference |= static_cast<unsigned char>(left[index]) ^ static_cast<unsigned char>(right[index]);
    }
    return difference == 0;
  }

  std::array<Entry, capacity> entries_;
  std::size_t count_ = 0;
};

}
