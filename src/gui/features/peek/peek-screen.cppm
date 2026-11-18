// The text a peek last read of its agent's screen, and the read in flight. Nothing here is
// exported: only the feature's own units name it, through State.
export module telar.gui.features.peek:screen;

import std;

import :target;
import telar.base.memory.allocators;
import telar.wire.content;
import telar.base.ds;

namespace telar::gui::features::peek {

  template <Allocator Memory>
  class PeekScreen {
  public:
    explicit PeekScreen(Memory& memory);

    void show(PeekTarget target) noexcept;
    void close() noexcept;

    [[nodiscard]] const ds::Option<PeekTarget>& target() const noexcept;
    [[nodiscard]] std::string_view text() const noexcept;
    [[nodiscard]] bool reading() const noexcept;
    [[nodiscard]] bool owns(std::uint64_t request) const noexcept;
    [[nodiscard]] ds::Option<ReadPane> request(std::uint64_t identity);
    bool fail(std::uint64_t identity) noexcept;
    [[nodiscard]] ds::Option<std::size_t> store(const PaneText& reply);

  private:
    String<Memory> text_;
    ds::Option<PeekTarget> target_;
    std::uint64_t request_id_ = 0;
  };

  extern template class PeekScreen<telar::Memory>;

}
