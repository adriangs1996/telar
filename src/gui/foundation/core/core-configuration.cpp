module telar.gui.foundation.core;

import std;

namespace telar::gui::inline foundation::inline core {

  PromptBindings::PromptBindings(std::initializer_list<PromptBinding> bindings) {
    for (const auto& binding : bindings) {
      push(binding);
    }
  }

  void PromptBindings::push(const PromptBinding& binding) {
    if (count_ == capacity) {
      throw std::length_error{"more prompt bindings than the configuration reads"};
    }

    entries_.atMut(count_++) = binding;
  }

  std::span<const PromptBinding> PromptBindings::view() const noexcept {
    return entries_.view().first(count_);
  }

  std::size_t PromptBindings::size() const noexcept {
    return count_;
  }

  const PromptBinding& PromptBindings::operator[](std::size_t index) const noexcept {
    return entries_[index];
  }

  const PromptBinding* PromptBindings::begin() const noexcept {
    return entries_.data();
  }

  const PromptBinding* PromptBindings::end() const noexcept {
    return std::to_address(entries_.view().first(count_).end());
  }

  bool operator==(const PromptBindings& left, const PromptBindings& right) noexcept {
    return std::ranges::equal(left.view(), right.view());
  }

}
