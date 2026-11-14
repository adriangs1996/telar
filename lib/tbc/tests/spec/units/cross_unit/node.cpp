#include "node.hpp"

#include <utility>

namespace cross_unit {
  template <typename memory>
  std::span<node<memory>> node<memory>::children() noexcept {
    return children_;
  }

  template <typename memory>
  node<memory>* node<memory>::find(std::string_view name) noexcept {
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
  std::size_t node<memory>::count() noexcept {
    std::size_t total = 1;

    for (auto& child : children_) {
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

  void visitor::visit(node<int>& target) {
    static_cast<void>(target.count());
  }

  void counter::visit(node<int>& target) {
    seen_ += target.count();
  }
}
