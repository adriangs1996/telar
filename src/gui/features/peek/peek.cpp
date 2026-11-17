module telar.gui.features.peek;

import std;

import :screen;
import telar.base.memory.allocators;
import telar.base.text;
import telar.gui.foundation.model;
import telar.wire.content;

namespace telar::gui::features::peek {

  template <Allocator Memory>
  PeekScreen<Memory>::PeekScreen(Memory& memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  void PeekScreen<Memory>::show(PeekTarget target) noexcept {
    target_ = target;
    text_.clear();
    request_id_ = 0;
  }

  template <Allocator Memory>
  void PeekScreen<Memory>::close() noexcept {
    target_.reset();
    text_.clear();
    request_id_ = 0;
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

    return start;
  }

  template class PeekScreen<telar::Memory>;

  State::State(Memory& memory)
      : screen_(memory) {}

  const std::optional<PeekTarget>& target(const State& state) noexcept {
    return Access::screen(state).target();
  }

  std::string_view text(const State& state) noexcept {
    return Access::screen(state).text();
  }

  bool reading(const State& state) noexcept {
    return Access::screen(state).reading();
  }

  const Agent<Memory>* find(std::span<const Agent<Memory>> agents, const PeekTarget& target) noexcept {
    const auto found = std::ranges::find_if(agents, [&](const auto& agent) {
      return agent.pane_id == target.agent.pane_id && agent.pane_generation == target.agent.pane_generation && agent.session_id == target.session;
    });

    return found == agents.end() ? nullptr : std::addressof(*found);
  }

  const Agent<Memory>* agent(const State& state, std::span<const Agent<Memory>> agents) noexcept {
    const auto& opened = target(state);

    return opened ? find(agents, *opened) : nullptr;
  }

  void open(State& state, PeekTarget target) noexcept {
    Access::screen(state).show(target);
  }

  void close(State& state) noexcept {
    Access::screen(state).close();
  }

  std::optional<ReadPane> read(State& state, std::uint64_t request_id) {
    return Access::screen(state).request(request_id);
  }

  bool fail(State& state, std::uint64_t request_id) noexcept {
    return Access::screen(state).fail(request_id);
  }

  std::optional<std::size_t> receive(State& state, const PaneText& reply) {
    return Access::screen(state).store(reply);
  }

  Submission submit(std::string_view text) {
    if (text.size() > PeekLimits::message_bytes) {
      throw std::length_error{"PeekMessageTooLong"};
    }

    const auto trimmed = runtime::trimText(text, " \t");
    if (trimmed.empty() || trimmed == "/open") {
      return {.command = PeekCommand::open};
    }

    if (trimmed == "/stop") {
      return {.command = PeekCommand::stop};
    }

    if (trimmed == "/diff") {
      return {.command = PeekCommand::diff};
    }

    return {.command = PeekCommand::message, .message = trimmed};
  }

}
