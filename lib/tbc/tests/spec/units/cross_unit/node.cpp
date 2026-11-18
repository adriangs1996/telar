#include "node.hpp"

#include <utility>

namespace cross_unit {
  template <typename memory>
  std::span<const node<memory>> node<memory>::children() const noexcept {
    return children_;
  }

  template <typename memory>
  const node<memory>* node<memory>::find(std::string_view name) const noexcept {
    for (const auto& child : children_) {
      if (child.name_ == name) {
        return &child;
      }
    }

    return nullptr;
  }

  template <typename memory>
  node<memory>* node<memory>::findMut(std::string_view name) noexcept {
    for (auto& child : children_) {
      if (child.name_ == name) {
        return &child;
      }
    }

    return nullptr;
  }

  template <typename memory>
  void node<memory>::append(node child) {
    children_.push_back(std::move(child));
  }

  template <typename memory>
  std::size_t node<memory>::count() const noexcept {
    std::size_t total = 1;

    for (const auto& child : children_) {
      total += child.count();
    }

    return total;
  }

  template <typename memory>
  void node<memory>::truncate(std::size_t depth) {
    if (depth == 0) {
      children_.clear();
      return;
    }

    if (!children_.empty()) {
      children_.front().truncate(depth - 1);
    }
  }

  template class node<int>;

  visitor::~visitor() = default;

  void visitor::visit(const node<int>& target) {
    static_cast<void>(target.count());
  }

  void visitor::prune(node<int>& target) {
    target.truncate(1);
  }

  void counter::visit(const node<int>& target) {
    seen_ += target.count();
  }

  void counter::prune(node<int>& target) {
    seen_ += target.count();
  }
}
