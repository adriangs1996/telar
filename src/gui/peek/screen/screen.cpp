module telar.gui.peek.screen;

import telar.base.text;

namespace telar::gui {

  PeekCommand PeekInput::command(std::string_view text) noexcept {
    text = runtime::trimText(text, " \t");
    if (text.empty() || text == "/open") {
      return PeekCommand::open;
    }

    if (text == "/stop") {
      return PeekCommand::stop;
    }

    return text == "/diff" ? PeekCommand::diff : PeekCommand::message;
  }

  template <Allocator Memory>
  PeekScreen<Memory>::PeekScreen(Memory& memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  void PeekScreen<Memory>::show(PeekTarget target) noexcept {
    target_ = target;
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  template <Allocator Memory>
  void PeekScreen<Memory>::close() noexcept {
    target_.reset();
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  template <Allocator Memory>
  const std::optional<PeekTarget>& PeekScreen<Memory>::target() const noexcept {
    return target_;
  }

  template <Allocator Memory>
  std::string_view PeekScreen<Memory>::text() const noexcept {
    return text_;
  }

  template <Allocator Memory>
  std::uint64_t PeekScreen<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  bool PeekScreen<Memory>::reading() const noexcept {
    return request_id_ != 0;
  }

  template <Allocator Memory>
  bool PeekScreen<Memory>::owns(std::uint64_t request) const noexcept {
    return request != 0 && request_id_ == request;
  }

  template <Allocator Memory>
  std::optional<ReadPane> PeekScreen<Memory>::request(std::uint64_t identity) {
    if (!target_ || reading()) {
      return std::nullopt;
    }

    if (identity == 0) {
      throw std::invalid_argument{"InvalidPeekRequest"};
    }

    request_id_ = identity;

    return ReadPane{
        .request_id = identity,
        .pane_id = target_->agent.pane_id,
        .pane_generation = target_->agent.pane_generation,
        .rows = PeekLimits::rows,
        .source = PaneTextSource::recent,
    };
  }

  template <Allocator Memory>
  bool PeekScreen<Memory>::fail(std::uint64_t identity) noexcept {
    if (!owns(identity)) {
      return false;
    }

    request_id_ = 0;

    return true;
  }

  template <Allocator Memory>
  std::optional<std::size_t> PeekScreen<Memory>::store(const PaneText& reply) {
    if (!owns(reply.request_id)) {
      return std::nullopt;
    }

    request_id_ = 0;
    if (!target_ || target_->agent.pane_id != reply.pane_id) {
      return std::nullopt;
    }

    auto start = reply.text.size() - std::min(reply.text.size(), PeekLimits::text_bytes);
    constexpr unsigned char continuation_mask = 0xc0;
    constexpr unsigned char continuation_bits = 0x80;

    while (start > 0 && start < reply.text.size() && (static_cast<unsigned char>(reply.text[start]) & continuation_mask) == continuation_bits) {
      ++start;
    }

    text_ = reply.text.substr(start);
    ++revision_;

    return start;
  }

  template <Allocator Memory>
  std::string_view PeekScreen<Memory>::lastLines(std::string_view text, std::uint16_t count) noexcept {
    const auto last = text.find_last_not_of(" \n\r\t");
    if (last == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - last - 1);
    auto start = text.size();
    std::uint16_t seen = 0;

    while (start > 0 && seen < count) {
      --start;
      if (text[start] == '\n') {
        ++seen;
        if (seen == count) {
          ++start;
          break;
        }
      }
    }

    text.remove_prefix(start);

    return text;
  }

  template class PeekScreen<telar::Memory>;
  template class PeekScreen<telar::ConcurrentMemory>;
  // What the session tests pass, through Session<SystemAllocator>.
  template class PeekScreen<telar::SystemAllocator>;

}
