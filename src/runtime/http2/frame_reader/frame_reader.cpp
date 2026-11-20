module telar.runtime.http2.frame_reader;

namespace telar::runtime {

  namespace {

    constexpr unsigned byte_bits = 8;

    // The number `bytes` hold, big-endian.
    constexpr std::uint32_t bigEndian(std::span<const std::uint8_t> bytes) noexcept {
      std::uint32_t value = 0;

      for (const auto byte : bytes) {
        value = (value << byte_bits) | byte;
      }

      return value;
    }

  }

  bool Http2Frame::has(Http2Flag flag) const noexcept {
    return (flags & static_cast<std::uint8_t>(flag)) != 0;
  }

  bool Http2Frame::containsHeaders() const noexcept {
    return kind == Http2FrameKind::headers || kind == Http2FrameKind::push_promise || kind == Http2FrameKind::continuation;
  }

  bool Http2FrameReader::incomplete() const noexcept {
    return header_length_ != 0;
  }

  void Http2FrameReader::decodeHeader() noexcept {
    // RFC 9113 4.1: a 24-bit length, the type, the flags, then a reserved bit and the 31-bit stream.
    constexpr std::size_t length_bytes = 3;
    constexpr std::size_t type_offset = 3;
    constexpr std::size_t flags_offset = 4;
    constexpr std::size_t stream_offset = 5;
    constexpr std::uint32_t stream_mask = 0x7FFF'FFFF;
    const auto header = header_.view();

    frame_.length = bigEndian(header.first<length_bytes>());
    frame_.kind = static_cast<Http2FrameKind>(header[type_offset]);
    frame_.flags = header[flags_offset];
    frame_.stream = bigEndian(header.subspan<stream_offset>()) & stream_mask;
    payload_offset_ = 0;
  }

  template <std::size_t Capacity>
  bool Http2StreamIds<Capacity>::start(std::uint32_t stream) noexcept {
    if (stream == 0 || std::ranges::find(ids_, stream) != ids_.end()) {
      return false;
    }

    const auto ids = ids_.viewMut();
    const auto available = std::ranges::find(ids, 0);
    if (available == ids.end()) {
      return false;
    }

    *available = stream;
    ++count_;
    return true;
  }

  template <std::size_t Capacity>
  bool Http2StreamIds<Capacity>::finish(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return false;
    }

    const auto ids = ids_.viewMut();
    const auto existing = std::ranges::find(ids, stream);
    if (existing == ids.end()) {
      return false;
    }

    *existing = 0;
    --count_;
    return true;
  }

  template <std::size_t Capacity>
  bool Http2StreamIds<Capacity>::full() const noexcept {
    return count_ == Capacity;
  }

  template <std::size_t Capacity>
  std::uint32_t Http2StreamIds<Capacity>::size() const noexcept {
    return count_;
  }

  bool Http2StreamTracker::startRequest(std::uint32_t stream) noexcept {
    return requests_.start(stream);
  }

  void Http2StreamTracker::finishRequest(std::uint32_t stream) noexcept {
    requests_.finish(stream);
  }

  bool Http2StreamTracker::requestsFull() const noexcept {
    return requests_.full();
  }

  bool Http2StreamTracker::setResponse(Response response) noexcept {
    if (response.stream == 0) {
      return false;
    }

    Response* available = nullptr;

    for (auto& entry : responses_.viewMut()) {
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

  auto Http2StreamTracker::response(std::uint32_t stream) const noexcept -> Response {
    for (const auto& entry : responses_) {
      if (entry.stream == stream) {
        return entry;
      }
    }

    return {};
  }

  void Http2StreamTracker::finishResponse(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return;
    }

    for (auto& entry : responses_.viewMut()) {
      if (entry.stream == stream) {
        entry = {};
        --response_count_;
        return;
      }
    }
  }

  bool Http2StreamTracker::hasResponses() const noexcept {
    return response_count_ != 0;
  }

  template class Http2StreamIds<2 * Http2StreamTracker::capacity>;

}
