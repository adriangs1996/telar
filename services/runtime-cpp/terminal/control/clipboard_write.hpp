#pragma once

#include "clipboard_metadata.hpp"
#include "../../memory/allocator.hpp"
#include <optional>

namespace telar::runtime::control {

struct ClipboardContentView {
  std::string_view mime;
  std::span<const std::uint8_t> data;
};

template <Allocator Memory>
class ClipboardWrite {
public:
  static constexpr std::size_t maximum_mimes = 64;
  static constexpr std::size_t maximum_aliases = 64;

  explicit ClipboardWrite(Memory &memory, const ClipboardMetadata &metadata, std::size_t limit)
      : metadata(metadata), memory_(memory), spool_(AllocatorRef<std::uint8_t, Memory>{memory}), limit_(limit) {}

  ClipboardStatus data(std::string_view mime, std::string_view encoded) {
    if (!current_ || entries_[*current_].mime.view() != mime) {
      if (finishCurrent() != ClipboardStatus::ok) {
        return ClipboardStatus::invalid;
      }
      current_.reset();
      for (std::size_t index = 0; index < entry_count_; ++index) {
        if (entries_[index].mime.view() == mime) {
          current_ = index;
          break;
        }
      }
      if (!current_) {
        if (entry_count_ == maximum_mimes) {
          return ClipboardStatus::ok;
        }
        current_ = entry_count_++;
        entries_[*current_].mime.assign(mime);
      }
      auto &entry = entries_[*current_];
      entry.offset = spool_.size();
      entry.length = 0;
    }

    for (const auto byte : encoded) {
      if (byte != '=' && base64::alphabet.find(byte) == std::string_view::npos) {
        return ClipboardStatus::invalid;
      }
      group_[group_size_++] = byte;
      if (group_size_ != group_.size()) {
        continue;
      }
      std::array<std::uint8_t, 3> decoded;
      const auto count = base64::decode({group_.data(), group_.size()}, decoded);
      if (!count) {
        return ClipboardStatus::invalid;
      }
      if (*count > limit_ - spool_.size()) {
        return ClipboardStatus::too_large;
      }
      reserve(*count);
      spool_.insert(spool_.end(), decoded.begin(), decoded.begin() + *count);
      group_size_ = 0;
    }
    return ClipboardStatus::ok;
  }

  ClipboardStatus alias(std::string_view mime, std::string_view encoded) {
    Vector<std::uint8_t, Memory> decoded{AllocatorRef<std::uint8_t, Memory>{memory_}};
    if (encoded.size() / 4 * 3 > limit_) {
      return ClipboardStatus::too_large;
    }
    decoded.resize(encoded.size() / 4 * 3);
    const auto length = base64::decode(encoded, decoded);
    if (!length) {
      return ClipboardStatus::invalid;
    }
    std::string_view remaining{reinterpret_cast<const char *>(decoded.data()), *length};
    try {
      validateUtf8(remaining);
    } catch (const EncodingError &) {
      return ClipboardStatus::invalid;
    }
    while (const auto name = token(remaining)) {
      if (name->contains('\0')) {
        return ClipboardStatus::invalid;
      }
      if (name->size() > ClipboardMetadata::maximum_mime) {
        continue;
      }
      auto index = alias_count_;
      for (std::size_t candidate = 0; candidate < alias_count_; ++candidate) {
        if (aliases_[candidate].name.view() == *name) {
          index = candidate;
          break;
        }
      }
      if (index == alias_count_) {
        if (alias_count_ == maximum_aliases) {
          continue;
        }
        aliases_[alias_count_++].name.assign(*name);
      }
      aliases_[index].target.assign(mime);
    }
    return ClipboardStatus::ok;
  }

  ClipboardStatus commit() {
    if (finishCurrent() != ClipboardStatus::ok) {
      return ClipboardStatus::invalid;
    }
    current_.reset();
    content_count_ = 0;
    for (const auto &entry : std::span{entries_}.first(entry_count_)) {
      contents_[content_count_++] = {entry.mime.view(), std::span<const std::uint8_t>{spool_}.subspan(entry.offset, entry.length)};
    }
    for (const auto &alias : std::span{aliases_}.first(alias_count_)) {
      std::optional<std::span<const std::uint8_t>> target;
      for (const auto &content : std::span{contents_}.first(content_count_)) {
        if (content.mime == alias.target.view()) {
          target = content.data;
          break;
        }
      }
      if (!target) {
        continue;
      }
      bool replaced = false;
      for (auto &content : std::span{contents_}.first(content_count_)) {
        if (content.mime == alias.name.view()) {
          content.data = *target;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        contents_[content_count_++] = {alias.name.view(), *target};
      }
    }

    // The desktop transport and platform clipboard have the same aggregate
    // budget, including alias representations that the desktop must copy.
    std::size_t total = 0;
    for (const auto &content : contents()) {
      if (content.data.size() > limit_ - total) {
        return ClipboardStatus::too_large;
      }
      total += content.data.size();
    }
    return ClipboardStatus::ok;
  }

  std::span<const ClipboardContentView> contents() const noexcept {
    return std::span{contents_}.first(content_count_);
  }

  static std::optional<std::string_view> token(std::string_view &remaining) noexcept {
    constexpr std::string_view whitespace = " \t\n\r\f\v";
    const auto first = remaining.find_first_not_of(whitespace);
    if (first == std::string_view::npos) {
      remaining = {};
      return std::nullopt;
    }
    remaining.remove_prefix(first);
    const auto end = remaining.find_first_of(whitespace);
    const auto result = remaining.substr(0, end);
    remaining = end == std::string_view::npos ? std::string_view{} : remaining.substr(end + 1);
    return result;
  }

  ClipboardMetadata metadata;

private:
  struct Entry {
    FixedText<ClipboardMetadata::maximum_mime> mime;
    std::size_t offset = 0;
    std::size_t length = 0;
  };

  struct Alias {
    FixedText<ClipboardMetadata::maximum_mime> name;
    FixedText<ClipboardMetadata::maximum_mime> target;
  };

  ClipboardStatus finishCurrent() noexcept {
    if (group_size_ != 0) {
      return ClipboardStatus::invalid;
    }
    if (current_) {
      entries_[*current_].length = spool_.size() - entries_[*current_].offset;
    }
    return ClipboardStatus::ok;
  }

  void reserve(std::size_t count) {
    if (count > spool_.capacity() - spool_.size()) {
      spool_.reserve(std::min(limit_, std::max(spool_.size() + count, std::max(initial_capacity, spool_.capacity() * 2))));
    }
  }

  static constexpr std::size_t initial_capacity = 4096;
  Memory &memory_;
  Vector<std::uint8_t, Memory> spool_;
  std::size_t limit_;
  std::array<Entry, maximum_mimes> entries_;
  std::array<Alias, maximum_aliases> aliases_;
  std::array<ClipboardContentView, maximum_mimes + maximum_aliases> contents_;
  std::size_t entry_count_ = 0;
  std::size_t alias_count_ = 0;
  std::size_t content_count_ = 0;
  std::optional<std::size_t> current_;
  std::array<char, 4> group_;
  std::size_t group_size_ = 0;
};

}
