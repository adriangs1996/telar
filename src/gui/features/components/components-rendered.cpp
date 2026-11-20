module telar.gui.features.components;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.config.core;
import telar.base.memory.allocators;

namespace telar::gui::features::components {

  CommandTabCopy::CommandTabCopy(const View& view)
      : count_(view.count) {
    std::size_t used = 0;
    const auto store = [&](std::string_view text) {
      if (text.size() > bytes_.size() - used) {
        throw std::length_error{"Command tab exceeds its byte capacity"};
      }

      std::ranges::copy(text, bytes_.viewMut().begin() + static_cast<std::ptrdiff_t>(used));
      used += text.size();

      return static_cast<std::uint16_t>(text.size());
    };

    for (std::size_t index = 0; index < view.count; ++index) {
      lengths_.atMut(index) = store(view.arguments[index]);
    }

    label_ = store(view.configured_label);
  }

  CommandTabCopy::View CommandTabCopy::view() const noexcept {
    View result;

    result.count = count_;
    const auto bytes = bytes_.view();
    std::size_t offset = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto argument = bytes.subspan(offset, lengths_[index]);

      result.arguments.atMut(index) = {argument.data(), argument.size()};
      offset += lengths_[index];
    }

    const auto label = bytes.subspan(offset, label_);

    result.configured_label = {label.data(), label.size()};

    return result;
  }

  template <Allocator Memory>
  ResolvedActions<Memory>::ResolvedActions(Memory& memory)
      : entries_(memory) {}

  template <Allocator Memory>
  void ResolvedActions<Memory>::add(ResolvedAction entry) {
    if (find(entry.action) == nullptr) {
      entries_.push(std::move(entry));
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
      : elements(memory),
        text(memory),
        steps(memory),
        bindings(memory),
        actions(memory) {}

  template <Allocator Memory>
  std::string_view RenderedElements<Memory>::view(ElementText range) const noexcept {
    if (range.length == 0 || range.offset > text.size() || range.length > text.size() - range.offset) {
      return {};
    }

    const auto chars = std::span{text.view()}.subspan(range.offset, range.length);

    return {chars.data(), chars.size()};
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
