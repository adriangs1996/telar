module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:reply;

import std;
import telar.base.memory.allocators;
import :pty_response_queue;
import telar.base.ds;

export namespace telar::runtime::control {

  // Generic over the caller's allocator, so it stays here.
  template <Allocator Memory>
  class TBC_GENERIC Reply {
    // The bytes a sealed reply moved out of its overflow, in their memory's region `a`.
    struct Storage {
      explicit Storage(tbc::view<ds::Vec<std::uint8_t, Memory>&&, tbc::lt::a> bytes)
          : bytes(std::move(bytes)) {}

      tbc::val_a<ds::Vec<std::uint8_t, Memory>> bytes;
    };

  public:
    static constexpr std::size_t maximum_bytes = PtyResponseQueue::total_byte_capacity;

    explicit Reply(Memory& memory)
        : memory_(memory),
          overflow_(memory) {}

    Reply(const Reply&) = delete;
    Reply& operator=(const Reply&) = delete;
    Reply(Reply&&) = delete;
    Reply& operator=(Reply&&) = delete;

    void append(std::string_view text) {
      if (text.empty()) {
        return;
      }

      if (owned_) {
        rejectSealedAppend();
      }

      if (text.size() > maximum_bytes - size_) {
        throw std::length_error{"Control reply exceeds its configured limit"};
      }

      if (size_ + text.size() <= inline_.size()) {
        std::memcpy(inline_.dataMut() + size_, text.data(), text.size());
      } else {
        if (overflow_.empty()) {
          overflow_.reserve(std::max(inline_.size() * 2, size_ + text.size()));
          overflow_.extend({inline_.begin(), inline_.begin() + size_});
        }

        if (size_ + text.size() > overflow_.capacity()) {
          overflow_.reserve(std::min(maximum_bytes, std::max(size_ + text.size(), overflow_.capacity() * 2)));
        }

        overflow_.extend({reinterpret_cast<const std::uint8_t*>(text.data()), text.size()});
      }

      size_ += text.size();
    }

    void number(std::uint64_t value) {
      ds::Array<char, std::numeric_limits<std::uint64_t>::digits10 + 1> bytes;
      const auto formatted = std::to_chars(bytes.dataMut(), bytes.dataMut() + bytes.size(), value);

      append({bytes.data(), static_cast<std::size_t>(formatted.ptr - bytes.data())});
    }

    void hex(std::uint64_t value, unsigned width, bool upper = false) {
      constexpr std::string_view lower_digits = "0123456789abcdef";
      constexpr std::string_view upper_digits = "0123456789ABCDEF";
      ds::Array<char, sizeof(value) * 2> bytes;

      width = std::min<unsigned>(width, bytes.size());
      const auto digits = upper ? upper_digits : lower_digits;
      auto offset = bytes.size();

      do {
        bytes.atMut(--offset) = digits[value & (digits.size() - 1)];
        value >>= 4;
      } while (value != 0);

      while (bytes.size() - offset < width) {
        bytes.atMut(--offset) = '0';
      }

      append({bytes.data() + offset, bytes.size() - offset});
    }

    template <typename Sink>
    bool publish(Sink& queue) {
      if (size_ == 0) {
        return true;
      }

      if (size_ <= inline_.size()) {
        return queue.tryPush(std::span<const std::uint8_t>{inline_}.first(size_));
      }

      seal();
      return queue.tryPushOwned(owned_->bytes, owned_);
    }

    void seal() {
      if (size_ > inline_.size() && !owned_) {
        owned_ = std::allocate_shared<Storage>(AllocatorRef<Storage, Memory>{memory_}, std::move(overflow_));
      }
    }

    void clear() noexcept {
      size_ = 0;
      overflow_.clear();
      owned_.reset();
    }

    std::size_t size() const noexcept {
      return size_;
    }

    void discard() noexcept {
      clear();
      overflow_ = ds::Vec<std::uint8_t, Memory>{overflow_.memory()};
    }

  private:
    [[noreturn, gnu::cold, gnu::noinline]] static void rejectSealedAppend() {
      throw std::logic_error{"Cannot append to a sealed control reply"};
    }

    Memory& memory_;
    ds::Array<std::uint8_t, PtyResponseQueue::message_byte_capacity> inline_;
    ds::Vec<std::uint8_t, Memory> overflow_;
    std::shared_ptr<Storage> owned_;
    std::size_t size_ = 0;
  };

}
