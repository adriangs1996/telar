#pragma once

#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGNode>
#include <concepts>
#include <cstddef>
#include <memory>
#include <stdexcept>
#include <utility>

namespace telar::gui::qt {

enum class SceneOrder : unsigned char {
  first,
  last,
};

inline std::unique_ptr<QSGImageNode> createSceneImage(const QQuickWindow &window) {
  std::unique_ptr<QSGImageNode> node{window.createImageNode()};
  if (!node) {
    throw std::runtime_error{"SceneImageUnavailable"};
  }

  return node;
}

template <std::derived_from<QSGNode> Node>
Node &adoptSceneNode(QSGNode &parent, std::unique_ptr<Node> node, SceneOrder order = SceneOrder::last) {
  auto &result = *node;
  if (order == SceneOrder::first) {
    parent.prependChildNode(node.release());
  } else {
    parent.appendChildNode(node.release());
  }

  return result;
}

template <std::derived_from<QSGNode> Node, typename... Arguments>
Node &appendSceneNode(QSGNode &parent, Arguments &&...arguments) {
  return adoptSceneNode(parent, std::make_unique<Node>(std::forward<Arguments>(arguments)...));
}

inline void clearSceneChildren(QSGNode &parent) {
  while (parent.firstChild() != nullptr) {
    const std::unique_ptr<QSGNode> child{parent.firstChild()};
    parent.removeChildNode(child.get());
  }
}

inline std::size_t sceneNodeDepth(const QSGNode &node) noexcept {
  std::size_t depth = 0;
  for (const auto *parent = node.parent(); parent != nullptr; parent = parent->parent()) {
    ++depth;
  }

  return depth;
}

inline bool sceneNodePrecedes(const QSGNode &first, const QSGNode &second) noexcept {
  const auto first_depth = sceneNodeDepth(first);
  const auto second_depth = sceneNodeDepth(second);
  const auto *left = &first;
  const auto *right = &second;
  for (auto depth = first_depth; depth > second_depth; --depth) {
    left = left->parent();
  }

  for (auto depth = second_depth; depth > first_depth; --depth) {
    right = right->parent();
  }

  if (left == right) {
    return first_depth < second_depth;
  }

  while (left->parent() != right->parent()) {
    left = left->parent();
    right = right->parent();
  }

  for (const auto *sibling = left->nextSibling(); sibling != nullptr; sibling = sibling->nextSibling()) {
    if (sibling == right) {
      return true;
    }
  }

  return false;
}

}
