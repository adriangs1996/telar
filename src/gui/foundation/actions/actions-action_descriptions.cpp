module telar.gui.foundation.actions;

import telar.base.memory.allocators;
import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline actions {

  template <Allocator Memory>
  ActionDescriptions<Memory>::ActionDescriptions(Memory& memory)
      : extended_(AllocatorRef<ExtendedActionDescription, Memory>{memory}) {}

  template <Allocator Memory>
  void ActionDescriptions<Memory>::replaceBindings() noexcept {
    extended_.clear();
  }

  template <Allocator Memory>
  const ExtendedActionDescription& ActionDescriptions<Memory>::at(std::int32_t index) const {
    if (index < 0 || static_cast<std::size_t>(index) >= extended_.size()) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return extended_[static_cast<std::size_t>(index)];
  }

  template <Allocator Memory>
  void ActionDescriptions<Memory>::replaceDefinition(std::int32_t index, DefinitionActionDescription definition) {
    if (!std::holds_alternative<DefinitionActionDescription>(at(index))) {
      throw std::invalid_argument{"Action does not name a panel or pick"};
    }

    extended_[static_cast<std::size_t>(index)] = definition;
  }

  template <Allocator Memory>
  std::int32_t ActionDescriptions<Memory>::retain(const ExtendedActionDescription& description) {
    if (extended_.size() == BindingLimits::bindings) {
      throw std::length_error{"Too many configured actions"};
    }

    const auto index = extended_.size();

    extended_.push_back(description);

    return static_cast<std::int32_t>(index);
  }

  template <Allocator Memory>
  std::int32_t ActionDescriptions<Memory>::registerCallback() {
    if (callbacks_ == maximum_callbacks) {
      throw std::length_error{"Too many Lua callbacks"};
    }

    return static_cast<std::int32_t>(callbacks_++);
  }

  template class ActionDescriptions<telar::Memory>;
  template class ActionDescriptions<telar::ConcurrentMemory>;

}
