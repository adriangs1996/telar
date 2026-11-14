module telar.runtime.http2.frame_reader;

namespace telar::runtime {

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
    frame_.length = (std::size_t{header_[0]} << 16) | (std::size_t{header_[1]} << 8) | header_[2];
    frame_.kind = static_cast<Http2FrameKind>(header_[3]);
    frame_.flags = header_[4];
    frame_.stream = (static_cast<std::uint32_t>(header_[5] & stream_high_mask) << 24) | (std::uint32_t{header_[6]} << 16) | (std::uint32_t{header_[7]} << 8) | header_[8];
    payload_offset_ = 0;
  }

  template <std::size_t Capacity>
  bool Http2StreamIds<Capacity>::start(std::uint32_t stream) noexcept {
    if (stream == 0 || std::ranges::find(ids_, stream) != ids_.end()) {
      return false;
    }

    const auto available = std::ranges::find(ids_, 0);
    if (available == ids_.end()) {
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

    const auto existing = std::ranges::find(ids_, stream);
    if (existing == ids_.end()) {
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

    for (auto& entry : responses_) {
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

    for (auto& entry : responses_) {
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

  template class Http2StreamIds<256>;

}
