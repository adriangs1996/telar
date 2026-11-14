module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.platform.stream_read_buffer;

namespace telar::runtime {

  std::size_t DelimitedRead::length() const noexcept {
    return length_;
  }

  StreamReadiness DelimitedRead::waiting() const noexcept {
    return waiting_;
  }

  void DelimitedRead::reset() noexcept {
    length_ = 0;
    complete_ = false;
    waiting_ = StreamReadiness::readable;
  }

  std::size_t DelimitedRead::delimiterEnd(std::string_view previous, std::string_view incoming, std::string_view delimiter) noexcept {
    const auto overlap = std::min(previous.size(), delimiter.size() - 1);

    for (std::size_t prefix = overlap; prefix != 0; --prefix) {
      const auto suffix = delimiter.size() - prefix;
      if (suffix <= incoming.size() && previous.ends_with(delimiter.substr(0, prefix)) && incoming.starts_with(delimiter.substr(prefix))) {
        return suffix;
      }
    }

    const auto position = incoming.find(delimiter);

    return position == std::string_view::npos ? position : position + delimiter.size();
  }

  DelimitedRead::Result DelimitedRead::interrupted(StreamResult result) noexcept {
    if (result.state == StreamResult::State::blocked) {
      waiting_ = result.waiting;
      return Result::pending;
    }

    return Result::ended;
  }

  template <std::size_t Capacity>
  std::size_t StreamReadBuffer<Capacity>::copyTo(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min(destination.size(), length_ - offset_);
    if (count != 0) {
      std::memcpy(destination.data(), storage_.bytes().data() + offset_, count);
      consume(count);
    }

    return count;
  }

  template <std::size_t Capacity>
  void StreamReadBuffer<Capacity>::consume(std::size_t count) noexcept {
    TELAR_ASSERT(count <= length_ - offset_);
    offset_ += count;
  }

  template <std::size_t Capacity>
  bool StreamReadBuffer<Capacity>::empty() const noexcept {
    return offset_ == length_;
  }

  template class StreamReadBuffer<16 * 1024>;

}
