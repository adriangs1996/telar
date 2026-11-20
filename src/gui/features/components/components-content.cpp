module telar.gui.features.components;

import std;

import telar.base.history;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.actions;
import telar.config.core;
import telar.base.ds;

namespace telar::gui::features::components {

  unsigned Node::effectivePriority() const noexcept {
    unsigned bonus = 0;

    if (tone == Tone::warning) {
      bonus = warning_bonus;
    } else if (tone == Tone::danger) {
      bonus = danger_bonus;
    }

    return std::min<unsigned>(priority + bonus, std::numeric_limits<std::uint8_t>::max());
  }

  bool Node::container() const noexcept {
    return kind == Kind::group || kind == Kind::callout || kind == Kind::actions;
  }

  template <Capacity Bounds>
  std::uint8_t Content<Bounds>::append(const Input& input) {
    if (node_count_ == Bounds.nodes) {
      throw std::length_error{"TooManyBarComponents"};
    }

    validateParent(input.node);
    if (input.node.value > Node::full_scale || input.node.marker.valueOr(0) > Node::full_scale) {
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
    std::ranges::copy(input.samples, samples_.viewMut().begin() + static_cast<std::ptrdiff_t>(sample_length_));
    sample_length_ += input.samples.size();
    node.action = Node::no_action;
    if (input.action) {
      node.action = static_cast<std::uint8_t>(action_count_);
      actions_.atMut(action_count_++) = *input.action;
    }

    const auto index = node_count_++;

    nodes_.atMut(index) = node;

    return static_cast<std::uint8_t>(index);
  }

  template <Capacity Bounds>
  void Content<Bounds>::clear() noexcept {
    node_count_ = 0;
    text_length_ = 0;
    sample_length_ = 0;
    action_count_ = 0;
  }

  template <Capacity Bounds>
  std::span<const Node> Content<Bounds>::nodes() const noexcept {
    return std::span{nodes_}.first(node_count_);
  }

  template <Capacity Bounds>
  bool Content<Bounds>::empty() const noexcept {
    return node_count_ == 0;
  }

  template <Capacity Bounds>
  std::string_view Content<Bounds>::text(Range range) const {
    validateRange(range, text_length_);
    if (range.length == 0) {
      return {};
    }

    const auto chars = text_.view().subspan(range.offset, range.length);

    return {chars.data(), chars.size()};
  }

  template <Capacity Bounds>
  std::span<const std::uint8_t> Content<Bounds>::samples(const Node& node) const {
    validateRange(node.samples, sample_length_);

    return std::span{samples_}.subspan(node.samples.offset, node.samples.length);
  }

  template <Capacity Bounds>
  ds::Option<BindingAction> Content<Bounds>::action(const Node& node) const {
    if (node.action == Node::no_action) {
      return ds::none;
    }

    if (node.action >= action_count_) {
      throw std::out_of_range{"InvalidBarAction"};
    }

    return actions_[node.action];
  }

  template <Capacity Bounds>
  Input Content<Bounds>::inputAt(std::size_t index) const {
    if (index >= node_count_) {
      throw std::out_of_range{"InvalidBarComponent"};
    }

    const auto& node = nodes_[index];

    return {.node = node, .text = text(node.text), .detail = text(node.detail), .url = text(node.url), .samples = samples(node), .action = action(node)};
  }

  template <Capacity Bounds>
  template <Capacity SourceBounds>
  void Content<Bounds>::keepFitting(const Content<SourceBounds>& source, const Parents* known_children) {
    if (static_cast<const void*>(this) == static_cast<const void*>(&source)) {
      throw std::invalid_argument{"Component fitting requires a distinct source"};
    }

    const auto count = source.nodes().size();
    ds::Array<unsigned, Node::maximum_nodes> ranks{};
    ds::Array<std::uint8_t, Node::maximum_nodes> order{};
    auto empty_containers = known_children == nullptr ? Parents{} : *known_children;

    for (std::size_t index = 0; index < count; ++index) {
      const auto& node = source.nodes()[index];

      ranks.atMut(index) = node.effectivePriority();
      order.atMut(index) = static_cast<std::uint8_t>(index);
      if (node.parent != Node::no_parent) {
        ranks.atMut(index) = std::min(ranks[index], ranks[node.parent]);
        empty_containers.atMut(node.parent) = false;
      }
    }

    const auto sorted = order.viewMut().first(count);

    std::ranges::sort(sorted, [&](auto left, auto right) {
      return ranks[left] == ranks[right] ? left < right : ranks[left] > ranks[right];
    });

    Parents kept{};
    Usage used;

    for (const auto index : sorted) {
      const auto& node = source.nodes()[index];
      if (empty_containers[index] || (node.parent != Node::no_parent && !kept[node.parent])) {
        continue;
      }

      const auto next = used.with(node);
      if (next.fits(Bounds)) {
        kept.atMut(index) = true;
        used = next;
      }
    }

    dropEmpty(source.nodes(), kept, known_children);
    clear();
    ds::Array<std::uint8_t, Node::maximum_nodes> copied{};

    for (std::size_t index = 0; index < count; ++index) {
      if (!kept[index]) {
        continue;
      }

      auto input = source.inputAt(index);
      if (input.node.parent != Node::no_parent) {
        input.node.parent = copied[input.node.parent];
      }

      copied.atMut(index) = append(input);
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::dropEmpty(std::span<const Node> source, Parents& kept, const Parents* known_children) noexcept {
    auto had_children = known_children == nullptr ? Parents{} : *known_children;
    ds::Array<std::uint8_t, Node::maximum_nodes> children{};

    for (std::size_t index = 0; index < source.size(); ++index) {
      const auto& node = source[index];
      if (node.parent != Node::no_parent) {
        had_children.atMut(node.parent) = true;
        if (kept[index]) {
          ++children.atMut(node.parent);
        }
      }
    }

    for (auto index = source.size(); index-- > 0;) {
      if (kept[index] && had_children[index] && children[index] == 0) {
        kept.atMut(index) = false;
        const auto& node = source[index];
        if (node.parent != Node::no_parent) {
          --children.atMut(node.parent);
        }
      }
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateParent(const Node& node) const {
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

  template <Capacity Bounds>
  void Content<Bounds>::validateText(std::string_view value) {
    validateUtf8(value);
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    if (std::ranges::any_of(value, [](unsigned char byte) {
          return byte < first_printable || byte == delete_control;
        })) {
      throw std::invalid_argument{"InvalidBarText"};
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateUrl(std::string_view value) {
    constexpr std::size_t maximum_url_bytes = 1024;
    if (!value.empty() && (value.size() > maximum_url_bytes || value.contains(' ') || (!value.starts_with("https://") && !value.starts_with("http://")))) {
      throw std::invalid_argument{"InvalidBarUrl"};
    }
  }

  template <Capacity Bounds>
  void Content<Bounds>::validateRange(Range range, std::size_t length) {
    if (range.offset > length || range.length > length - range.offset) {
      throw std::out_of_range{"InvalidBarContentRange"};
    }
  }

  template <Capacity Bounds>
  Range Content<Bounds>::copyText(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint16_t>(text_length_), .length = static_cast<std::uint16_t>(value.size())};

    std::ranges::copy(value, text_.viewMut().begin() + static_cast<std::ptrdiff_t>(text_length_));
    text_length_ += value.size();

    return range;
  }

  template <Capacity Bounds>
  Content<Bounds>::Usage Content<Bounds>::Usage::with(const Node& node) const noexcept {
    return {.nodes = nodes + 1, .text = text + node.text.length + node.detail.length + node.url.length, .samples = samples + node.samples.length, .actions = actions + (node.action != Node::no_action ? 1 : 0)};
  }

  template <Capacity Bounds>
  bool Content<Bounds>::Usage::fits(Capacity room) const noexcept {
    return nodes <= room.nodes && text <= room.text && samples <= room.samples && actions <= room.actions;
  }

  ComponentColors::Color ComponentColors::index(std::uint8_t index) noexcept {
    return CellColor{.kind = CellColor::Kind::indexed, .channels = {index, 0, 0}};
  }

  ds::Option<ComponentColors::Color> ComponentColors::name(std::string_view name) noexcept {
    return ColorName::parse(name);
  }

  runtime::FixedText<Node::maximum_icon_bytes> ValueMapper::iconName(std::string_view name) {
    ds::Array<char, Node::maximum_icon_bytes> normalized{};
    if (name.size() > normalized.size()) {
      throw std::invalid_argument{"Component icon name exceeds its limit"};
    }

    std::ranges::transform(name, normalized.viewMut().begin(), [](char byte) {
      return byte == '-' ? '_' : runtime::asciiLower(byte);
    });

    runtime::FixedText<Node::maximum_icon_bytes> result;

    result.assign({normalized.data(), name.size()});

    return result;
  }

  ds::Option<runtime::FixedText<Node::maximum_icon_bytes>> ValueMapper::icon(const ds::Option<std::string_view>& name) {
    return name ? ds::Option{iconName(*name)} : ds::none;
  }

  ds::Option<Mark> ValueMapper::mark(ds::Option<runtime::config::UiMark> mark) noexcept {
    return mark ? ds::Option{static_cast<Mark>(std::to_underlying(*mark))} : ds::none;
  }

  Tone ValueMapper::tone(runtime::config::ComponentTone tone) noexcept {
    return static_cast<Tone>(std::to_underlying(tone));
  }

  std::uint16_t ValueMapper::fraction(double number) noexcept {
    return static_cast<std::uint16_t>(std::round(std::clamp(number, 0.0, 1.0) * Node::full_scale));
  }

  template class Content<bar_capacity>;
  template class Content<panel_capacity>;
  template class Content<staging_capacity>;
  template void BarContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);
  template void PanelContent::keepFitting<staging_capacity>(const StagedContent& source, const Parents* known_children);

}
