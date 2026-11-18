module telar.gui.features.components;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.config.core;
import telar.base.memory.allocators;

namespace telar::gui::features::components {

  CommandTabCopy::CommandTabCopy(const View& view) {
    std::size_t used = 0;
    const auto store = [&](std::string_view text) {
      if (text.size() > bytes_.size() - used) {
        throw std::length_error{"Command tab exceeds its byte capacity"};
      }

      std::ranges::copy(text, bytes_.viewMut().begin() + static_cast<std::ptrdiff_t>(used));
      used += text.size();

      return static_cast<std::uint16_t>(text.size());
    };

    count_ = view.count;
    for (std::size_t index = 0; index < view.count; ++index) {
      lengths_.atMut(index) = store(view.arguments[index]);
    }

    label_ = store(view.configured_label);
  }

  CommandTabCopy::View CommandTabCopy::view() const noexcept {
    View result;

    result.count = count_;
    std::size_t offset = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      result.arguments.atMut(index) = {bytes_.data() + offset, lengths_[index]};
      offset += lengths_[index];
    }

    result.configured_label = {bytes_.data() + offset, label_};

    return result;
  }

  template <Allocator Memory>
  ResolvedActions<Memory>::ResolvedActions(Memory& memory)
      : entries_(AllocatorRef<ResolvedAction, Memory>{memory}) {}

  template <Allocator Memory>
  void ResolvedActions<Memory>::add(ResolvedAction entry) {
    if (find(entry.action) == nullptr) {
      entries_.push_back(std::move(entry));
    }
  }

  template <Allocator Memory>
  const ResolvedAction* ResolvedActions<Memory>::find(BindingAction action) const noexcept {
    const auto found = std::ranges::find(entries_, action, &ResolvedAction::action);

    return found == entries_.end() ? nullptr : &*found;
  }

  template <Allocator Memory>
  bool ResolvedActions<Memory>::contains(BindingAction action) const noexcept {
    return find(action) != nullptr;
  }

  template <Capacity Bounds, Allocator Memory>
  RenderedContent<Bounds, Memory>::RenderedContent(Memory& memory)
      : actions(memory) {}

  template <Allocator Memory>
  ResolvedEffects<Memory>::ResolvedEffects(Memory& memory)
      : actions(memory) {}

  template <Allocator Memory>
  RenderedElements<Memory>::RenderedElements(Memory& memory)
      : elements(AllocatorRef<Element, Memory>{memory}),
        text(AllocatorRef<char, Memory>{memory}),
        steps(AllocatorRef<CanvasStep, Memory>{memory}),
        bindings(AllocatorRef<BindingAction, Memory>{memory}),
        actions(memory) {}

  template <Allocator Memory>
  std::string_view RenderedElements<Memory>::view(ElementText range) const noexcept {
    return range.length == 0 || range.offset > text.size() || range.length > text.size() - range.offset ? std::string_view{} : std::string_view{text.data() + range.offset, range.length};
  }

  template class ResolvedActions<telar::Memory>;
  template class ResolvedActions<telar::ConcurrentMemory>;
  template struct RenderedContent<bar_capacity, telar::Memory>;
  template struct RenderedContent<panel_capacity, telar::Memory>;
  template struct RenderedContent<bar_capacity, telar::ConcurrentMemory>;
  template struct RenderedContent<panel_capacity, telar::ConcurrentMemory>;
  template struct ResolvedEffects<telar::Memory>;
  template struct ResolvedEffects<telar::ConcurrentMemory>;
  template struct RenderedElements<telar::Memory>;
  template struct RenderedElements<telar::ConcurrentMemory>;

}
