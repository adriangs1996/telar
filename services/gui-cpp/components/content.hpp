#pragma once

#include "input/action.hpp"
#include "node.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::components {

struct Capacity {
  std::size_t nodes;
  std::size_t text;
  std::size_t samples;
  std::size_t actions;
};

template <Capacity Bounds>
class Content {
  static_assert(Bounds.nodes <= Node::maximum_nodes && Bounds.actions <= Node::maximum_nodes);
  static_assert(Bounds.text <= std::numeric_limits<std::uint16_t>::max() && Bounds.samples <= std::numeric_limits<std::uint16_t>::max());

public:
  static constexpr auto capacity = Bounds;
  using Parents = std::array<bool, Node::maximum_nodes>;

  // Validate and reserve the complete node before changing any owned storage.
  std::uint8_t append(const Input &input) {
    if (node_count_ == Bounds.nodes) {
      throw std::length_error{"TooManyBarComponents"};
    }

    validateParent(input.node);
    if (input.node.value > Node::full_scale || input.node.marker.value_or(0) > Node::full_scale) {
      throw std::invalid_argument{"InvalidBarValue"};
    }

    if (input.samples.size() > Node::maximum_samples || input.samples.size() > Bounds.samples - sample_length_) {
      throw std::length_error{"TooManyBarSamples"};
    }

    if (input.action && action_count_ == Bounds.actions) {
      throw std::length_error{"TooManyBarActions"};
    }

    auto remaining = Bounds.text - text_length_;
    for (const auto value : {input.text, input.detail, input.url}) {
      if (value.size() > remaining) {
        throw std::length_error{"BarTextTooLong"};
      }

      remaining -= value.size();
      validateText(value);
    }

    validateUrl(input.url);
    auto node = input.node;
    node.priority = std::min(node.priority, Node::maximum_priority);
    node.text = copyText(input.text);
    node.detail = copyText(input.detail);
    node.url = copyText(input.url);
    node.samples = {.offset = static_cast<std::uint16_t>(sample_length_), .length = static_cast<std::uint16_t>(input.samples.size())};
    std::ranges::copy(input.samples, samples_.begin() + static_cast<std::ptrdiff_t>(sample_length_));
    sample_length_ += input.samples.size();
    node.action = Node::no_action;
    if (input.action) {
      node.action = static_cast<std::uint8_t>(action_count_);
      actions_[action_count_++] = *input.action;
    }

    const auto index = node_count_++;
    nodes_[index] = node;

    return static_cast<std::uint8_t>(index);
  }

  void clear() noexcept {
    node_count_ = 0;
    text_length_ = 0;
    sample_length_ = 0;
    action_count_ = 0;
  }

  [[nodiscard]] std::span<const Node> nodes() const noexcept {
    return std::span{nodes_}.first(node_count_);
  }

  [[nodiscard]] bool empty() const noexcept {
    return node_count_ == 0;
  }

  [[nodiscard]] std::string_view text(Range range) const {
    validateRange(range, text_length_);
    if (range.length == 0) {
      return {};
    }

    return {text_.data() + range.offset, range.length};
  }

  [[nodiscard]] std::span<const std::uint8_t> samples(const Node &node) const {
    validateRange(node.samples, sample_length_);

    return std::span{samples_}.subspan(node.samples.offset, node.samples.length);
  }

  [[nodiscard]] std::optional<BindingAction> action(const Node &node) const {
    if (node.action == Node::no_action) {
      return std::nullopt;
    }

    if (node.action >= action_count_) {
      throw std::out_of_range{"InvalidBarAction"};
    }

    return actions_[node.action];
  }

  [[nodiscard]] Input inputAt(std::size_t index) const {
    if (index >= node_count_) {
      throw std::out_of_range{"InvalidBarComponent"};
    }

    const auto &node = nodes_[index];

    return {.node = node, .text = text(node.text), .detail = text(node.detail), .url = text(node.url), .samples = samples(node), .action = action(node)};
  }

  // Rank children with their container, reserve by priority, then copy in document order.
  template <Capacity SourceBounds>
  void keepFitting(const Content<SourceBounds> &source, const Parents *known_children = nullptr) {
    if (static_cast<const void *>(this) == static_cast<const void *>(&source)) {
      throw std::invalid_argument{"Component fitting requires a distinct source"};
    }

    const auto count = source.nodes().size();
    std::array<unsigned, Node::maximum_nodes> ranks{};
    std::array<std::uint8_t, Node::maximum_nodes> order{};
    auto empty_containers = known_children == nullptr ? Parents{} : *known_children;
    for (std::size_t index = 0; index < count; ++index) {
      const auto &node = source.nodes()[index];
      ranks[index] = node.effectivePriority();
      order[index] = static_cast<std::uint8_t>(index);
      if (node.parent != Node::no_parent) {
        ranks[index] = std::min(ranks[index], ranks[node.parent]);
        empty_containers[node.parent] = false;
      }
    }

    const auto sorted = std::span{order}.first(count);
    std::ranges::sort(sorted, [&](auto left, auto right) {
      return ranks[left] == ranks[right] ? left < right : ranks[left] > ranks[right];
    });
    Parents kept{};
    Usage used;
    for (const auto index : sorted) {
      const auto &node = source.nodes()[index];
      if (empty_containers[index] || (node.parent != Node::no_parent && !kept[node.parent])) {
        continue;
      }

      const auto next = used.with(node);
      if (next.fits(Bounds)) {
        kept[index] = true;
        used = next;
      }
    }

    dropEmpty(source.nodes(), kept, known_children);
    clear();
    std::array<std::uint8_t, Node::maximum_nodes> copied{};
    for (std::size_t index = 0; index < count; ++index) {
      if (!kept[index]) {
        continue;
      }

      auto input = source.inputAt(index);
      if (input.node.parent != Node::no_parent) {
        input.node.parent = copied[input.node.parent];
      }

      copied[index] = append(input);
    }
  }

private:
  struct Usage {
    std::size_t nodes = 0;
    std::size_t text = 0;
    std::size_t samples = 0;
    std::size_t actions = 0;

    [[nodiscard]] Usage with(const Node &node) const noexcept {
      return {.nodes = nodes + 1, .text = text + node.text.length + node.detail.length + node.url.length, .samples = samples + node.samples.length, .actions = actions + (node.action != Node::no_action ? 1 : 0)};
    }

    [[nodiscard]] bool fits(Capacity room) const noexcept {
      return nodes <= room.nodes && text <= room.text && samples <= room.samples && actions <= room.actions;
    }
  };

  static void dropEmpty(std::span<const Node> source, Parents &kept, const Parents *known_children) noexcept {
    auto had_children = known_children == nullptr ? Parents{} : *known_children;
    std::array<std::uint8_t, Node::maximum_nodes> children{};
    for (std::size_t index = 0; index < source.size(); ++index) {
      const auto &node = source[index];
      if (node.parent != Node::no_parent) {
        had_children[node.parent] = true;
        if (kept[index]) {
          ++children[node.parent];
        }
      }
    }

    for (auto index = source.size(); index-- > 0;) {
      if (kept[index] && had_children[index] && children[index] == 0) {
        kept[index] = false;
        const auto &node = source[index];
        if (node.parent != Node::no_parent) {
          --children[node.parent];
        }
      }
    }
  }

  void validateParent(const Node &node) const {
    if (node.parent == Node::no_parent) {
      if (node.tooltip) {
        throw std::invalid_argument{"InvalidBarParent"};
      }

      return;
    }

    if (node.parent >= node_count_ || !nodes_[node.parent].container() || (node.tooltip && nodes_[node.parent].kind != Kind::group)) {
      throw std::invalid_argument{"InvalidBarParent"};
    }
  }

  static void validateText(std::string_view value) {
    validateUtf8(value);
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    if (std::ranges::any_of(value, [](unsigned char byte) {
          return byte < first_printable || byte == delete_control;
        })) {
      throw std::invalid_argument{"InvalidBarText"};
    }
  }

  static void validateUrl(std::string_view value) {
    constexpr std::size_t maximum_url_bytes = 1024;
    if (!value.empty() && (value.size() > maximum_url_bytes || value.contains(' ') || (!value.starts_with("https://") && !value.starts_with("http://")))) {
      throw std::invalid_argument{"InvalidBarUrl"};
    }
  }

  static void validateRange(Range range, std::size_t length) {
    if (range.offset > length || range.length > length - range.offset) {
      throw std::out_of_range{"InvalidBarContentRange"};
    }
  }

  Range copyText(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint16_t>(text_length_), .length = static_cast<std::uint16_t>(value.size())};
    std::ranges::copy(value, text_.begin() + static_cast<std::ptrdiff_t>(text_length_));
    text_length_ += value.size();

    return range;
  }

  std::array<Node, Bounds.nodes> nodes_{};
  std::array<char, Bounds.text> text_{};
  std::array<std::uint8_t, Bounds.samples> samples_{};
  std::array<BindingAction, Bounds.actions> actions_{};
  std::size_t node_count_ = 0;
  std::size_t text_length_ = 0;
  std::size_t sample_length_ = 0;
  std::size_t action_count_ = 0;
};

inline constexpr Capacity bar_capacity{.nodes = 64, .text = 4096, .samples = 256, .actions = 32};
inline constexpr Capacity panel_capacity{.nodes = 128, .text = std::size_t{16} * std::size_t{1024}, .samples = 1024, .actions = 32};
inline constexpr Capacity staging_capacity{.nodes = Node::maximum_nodes, .text = std::size_t{32} * std::size_t{1024}, .samples = 2048, .actions = 64};
using BarContent = Content<bar_capacity>;
using PanelContent = Content<panel_capacity>;
using StagedContent = Content<staging_capacity>;

}
