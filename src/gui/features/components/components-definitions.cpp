module telar.gui.features.components;

import std;

import telar.base.text;
import telar.gui.foundation.core;

namespace telar::gui::features::components {

  void Heading::assign(const runtime::config::DefinitionHeading& heading) {
    name.assign(heading.name);
    title.assign(heading.title);
  }

  Definitions::Definitions() noexcept {
    slots_.fill(no_reference);
    sources_[static_cast<std::size_t>(Position::bottom_left)].kind = SourceKind::metrics;
    sources_[static_cast<std::size_t>(Position::bottom_right)].kind = SourceKind::tabs;
    sources_[static_cast<std::size_t>(Position::footer_left)].kind = SourceKind::metrics;
  }

  const Source& Definitions::source(Position position) const {
    return sources_.at(static_cast<std::size_t>(position));
  }

  int Definitions::slot(Slot slot) const noexcept {
    return slots_[static_cast<std::size_t>(slot)];
  }

  bool Definitions::drawsAny() const noexcept {
    return std::ranges::any_of(slots_, [](int reference) {
      return reference != no_reference;
    });
  }

  std::span<const Panel> Definitions::panels() const noexcept {
    return std::span{panels_}.first(panel_count_);
  }

  std::span<const Pick> Definitions::picks() const noexcept {
    return std::span{picks_}.first(pick_count_);
  }

  void Definitions::defineSource(Position position, const Source& source) {
    sources_[std::to_underlying(position)] = source;
  }

  void Definitions::defineSlot(Slot slot, int reference) noexcept {
    slots_[static_cast<std::size_t>(slot)] = reference;
  }

  void Definitions::definePanel(std::size_t index, const Panel& panel) {
    panels_[index] = panel;
  }

  void Definitions::definePick(std::size_t index, const Pick& pick) {
    picks_[index] = pick;
  }

  void Definitions::count(std::optional<std::size_t> panels, std::optional<std::size_t> picks) noexcept {
    panel_count_ = panels.value_or(panel_count_);
    pick_count_ = picks.value_or(pick_count_);
  }

  bool builtinSource(SourceKind kind) noexcept {
    return kind == SourceKind::metrics || kind == SourceKind::machines;
  }

  BarContent builtinContent(SourceKind kind) {
    BarContent content;
    Input input{};

    input.node.priority = builtin_priority;
    if (kind == SourceKind::metrics) {
      input.node.kind = Kind::group;
      input.text = "system";
      const auto group = content.append(input);

      input.text = {};
      input.node.kind = Kind::metric;
      input.node.parent = group;
      for (const auto metric : std::array{BarMetric::battery, BarMetric::cpu, BarMetric::memory}) {
        input.node.metric = metric;
        content.append(input);
      }
    } else if (kind == SourceKind::machines) {
      input.node.kind = Kind::machines;
      content.append(input);
    }

    return content;
  }

}
