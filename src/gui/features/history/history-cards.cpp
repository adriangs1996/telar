module telar.gui.features.history;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.text;

namespace telar::gui::features::history {

  HistoryRowGeometry HistoryRowGeometry::derive(Rect bounds, ChromeMetrics chrome, float row_height, HistoryRowMeasurements measurements) noexcept {
    HistoryRowGeometry result;

    result.frame = bounds.inset(chrome.px(horizontal_inset), chrome.px(vertical_inset));
    const auto line_x = result.frame.x + chrome.px(command_inset);
    const Rect line{.x = line_x, .y = result.frame.y, .width = std::max(0.0F, result.frame.right() - chrome.px(right_inset) - line_x), .height = std::max(0.0F, row_height - chrome.px(2 * vertical_inset))};

    result.status = {.x = result.frame.x + chrome.px(status_inset), .y = line.y, .width = chrome.px(status_width), .height = line.height};
    const auto gap = chrome.px(fact_gap);
    Facts facts;

    if (measurements.agent) {
      facts.append(Kind::provider, std::round(chrome.px(provider_side)), gap);
    }

    if (!measurements.expanded && measurements.show_cwd && measurements.has_cwd) {
      facts.append(Kind::cwd, measurements.cwd, gap);
    }

    if (measurements.has_time) {
      facts.append(Kind::time, measurements.time, gap);
    }

    if (!measurements.expanded && measurements.command + facts.width > line.width) {
      facts.removeCwd(gap);
    }

    while (facts.count > 0 && facts.width - gap > line.width - chrome.px(minimum_command)) {
      facts.remove(facts.count - 1, gap);
    }

    facts.width = std::max(0.0F, facts.width - gap);
    result.command = line;
    const auto reserved = facts.count == 0 ? 0 : facts.width + gap;

    result.command.width = std::max(0.0F, line.width - reserved);
    auto x = line.right() - facts.width;

    for (std::size_t index = 0; index < facts.count; ++index) {
      const auto token = facts.tokens[index];
      const Rect area{.x = x, .y = line.y, .width = token.width, .height = line.height};

      switch (token.kind) {
      case Kind::provider:
        result.provider = {.x = x, .y = line.y + std::floor((line.height - token.width) / 2), .width = token.width, .height = token.width};
        break;
      case Kind::cwd:
        result.cwd = area;
        break;
      case Kind::time:
        result.time = area;
        break;
      }

      x += token.width + gap;
    }

    return result;
  }

  void HistoryRowGeometry::Facts::append(Kind kind, float advance, float gap) noexcept {
    tokens.atMut(count++) = {.kind = kind, .width = advance};
    width += advance + gap;
  }

  void HistoryRowGeometry::Facts::remove(std::size_t index, float gap) noexcept {
    width -= tokens[index].width + gap;
    for (auto next = index + 1; next < count; ++next) {
      tokens.atMut(next - 1) = tokens[next];
    }

    --count;
  }

  void HistoryRowGeometry::Facts::removeCwd(float gap) noexcept {
    for (std::size_t index = 0; index < count; ++index) {
      if (tokens[index].kind == Kind::cwd) {
        remove(index, gap);

        return;
      }
    }
  }

  tbc::view<std::string_view, tbc::lt::a> HistoryCard::line(tbc::view<std::string_view, tbc::lt::a> command, HistoryCardLine line) noexcept {
    return command.substr(std::min<std::size_t>(line.offset, command.size()), line.length);
  }

  HistoryCard HistoryCard::measure(const HistoryRowGeometry& row, ChromeMetrics chrome, HistoryCardMetrics metrics, std::string_view command) noexcept {
    HistoryCard result;

    result.line_limit = lineLimit(chrome, metrics);
    const auto columns = std::floor(row.command.width / std::max(1.0F, metrics.cell_width));
    const auto bounded_columns = static_cast<std::uint16_t>(std::clamp(columns, 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    WrappedLines wrapped{command, bounded_columns, true};
    std::uint16_t total = 0;

    while (total < result.line_limit + more_bound) {
      const auto line = wrapped.next();
      if (!line) {
        break;
      }

      if (total < result.line_limit) {
        result.lines.atMut(total) = {.offset = static_cast<std::uint32_t>(line->data() - command.data()), .length = static_cast<std::uint32_t>(line->size())};
      }

      ++total;
    }

    result.shown = std::min(total, result.line_limit);
    result.more = total - result.shown;
    const auto top_inset = std::max(0.0F, std::floor((row.command.height - metrics.cell_height) / 2));
    const auto command_height = static_cast<float>(result.shown) * metrics.cell_height;
    const auto meta_height = std::max(chrome.px(minimum_meta_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(meta_padding));

    result.text_y = row.command.y + top_inset;
    result.meta = {.x = row.command.x, .y = result.text_y + command_height + chrome.px(meta_gap), .width = std::max(0.0F, row.frame.right() - chrome.px(bottom_inset) - row.command.x), .height = meta_height};
    result.intrinsic_height = chrome.px(2 * HistoryRowGeometry::vertical_inset) + top_inset + command_height + chrome.px(meta_gap) + meta_height + chrome.px(bottom_inset);
    const auto opened_height = std::round(metrics.row_height + std::max(0.0F, result.intrinsic_height - metrics.row_height));
    const auto tallest = std::max(metrics.row_height, metrics.viewport_height - chrome.px(viewport_clearance));

    result.height = metrics.viewport_height > 0 ? std::min(tallest, opened_height) : opened_height;

    return result;
  }

  std::uint16_t HistoryCard::lineLimit(ChromeMetrics chrome, HistoryCardMetrics metrics) noexcept {
    if (metrics.viewport_height <= 0) {
      return maximum_lines;
    }

    const auto budget = (metrics.viewport_height * viewport_share) - metrics.row_height - chrome.px(viewport_reservation);
    const auto count = std::floor(budget / std::max(1.0F, metrics.cell_height)) + 1;

    return static_cast<std::uint16_t>(std::clamp(count, 1.0F, static_cast<float>(maximum_lines)));
  }

  void HistoryFacts::ErasedSink::operator()(std::string_view text, PaletteRole color) const {
    call(target, text, color);
  }

  void HistoryFacts::visitErased(const HistoryFactData& data, ErasedSink sink) {
    notice(data, sink);
    if (data.show_directory && !data.directory.empty()) {
      sink(data.directory, PaletteRole::subtext0);
    }

    if (data.status == HistoryStatus::running) {
      sink("running", PaletteRole::teal);
    } else if (data.status == HistoryStatus::interrupted) {
      sink("stopped", PaletteRole::yellow);
    } else if (data.exit_code && *data.exit_code != 0) {
      BoundedText<outcome_capacity> text;

      text.append("exit ");
      const auto code = static_cast<std::int64_t>(*data.exit_code);
      if (code < 0) {
        text.append("-");
      }

      text.appendDecimal(static_cast<std::uint64_t>(code < 0 ? -code : code));
      sink(text.view(), PaletteRole::red);
    }

    if (data.status != HistoryStatus::running) {
      sink(data.duration, PaletteRole::subtext0);
    }

    if (data.has_time) {
      sink(data.age, PaletteRole::subtext0);
    }

    if (data.agent) {
      sink(data.provider.empty() ? "agent" : data.provider, PaletteRole::subtext0);
    }
  }

  void HistoryFacts::notice(const HistoryFactData& data, ErasedSink& sink) {
    if (data.truncated) {
      sink("capture cut short, cannot paste", PaletteRole::yellow);
    } else if (!data.loaded) {
      sink("loading the complete command…", PaletteRole::subtext0);
    } else if (data.more != 0) {
      BoundedText<notice_capacity> text;

      text.append("+");
      text.appendDecimal(data.more);
      if (data.more == HistoryCard::more_bound) {
        text.append("+");
      }

      text.append(" more lines  ·  ");
      text.append(HistoryActions::inspectionKey(data.key_style));
      text.append(" shows all");
      sink(text.view(), PaletteRole::accent);
    }
  }

  auto HistoryFooter::range(HistoryFooterOptions options) -> Range {
    Range result;

    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + 1);
    result.append("–");
    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + options.count);
    if (options.has_more) {
      result.append(options.key_style == HistoryKeyStyle::mac ? "  ·  ⇞ older" : "  ·  PgUp older");
    }

    if (options.fuzzy && options.has_query) {
      result.append("  ·  fuzzy");
    }

    return result;
  }

  HistoryFooterGeometry HistoryFooterGeometry::derive(Rect area, ChromeMetrics chrome, const HistoryFooterMeasurements& measured) noexcept {
    HistoryFooterGeometry result;

    if (area.empty()) {
      return result;
    }

    result.separator = {.x = area.x, .y = area.y, .width = area.width, .height = separator_height};
    const auto left = area.x + chrome.px(horizontal_inset);
    const auto limit = area.right() - chrome.px(horizontal_inset);

    if (measured.error) {
      result.error = {.x = left, .y = area.y, .width = std::max(0.0F, limit - left), .height = area.height};
      result.error_visible = true;

      return result;
    }

    auto x = left - chrome.px(HistoryHintGeometry::padding);
    const auto available = std::min(measured.count, measured.hints.size());

    for (std::size_t index = 0; index < available; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.hints[index]);
      if (x + width > limit) {
        break;
      }

      const Rect bounds{.x = x, .y = area.y + chrome.px(vertical_inset), .width = width, .height = std::max(0.0F, area.height - chrome.px(vertical_inset * 2))};

      result.hints.atMut(index) = HistoryHintGeometry::derive(bounds, chrome, measured.hints[index]);
      ++result.count;
      x += width + chrome.px(hint_gap);
    }

    if (!measured.empty && x + chrome.px(range_gap) + measured.range <= limit) {
      result.range = {.x = limit - measured.range, .y = area.y, .width = measured.range, .height = area.height};
      result.range_visible = true;
    }

    return result;
  }

  HistoryMetaGeometry HistoryMetaGeometry::derive(Rect bounds, ChromeMetrics chrome, const HistoryMetaMeasurements& measured) noexcept {
    HistoryMetaGeometry result;

    if (bounds.empty()) {
      return result;
    }

    float total = 0;
    const auto available_actions = measured.selected ? HistoryActions::count - static_cast<std::size_t>(!measured.pane_open) : 0;

    for (std::size_t index = 0; index < available_actions; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);
      if (bounds.width - total - width < chrome.px(HistoryRowGeometry::minimum_command)) {
        break;
      }

      total += width + chrome.px(action_gap);
      ++result.action_count;
    }

    auto x = bounds.right() - total;

    for (std::size_t index = 0; index < result.action_count; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);

      result.actions.atMut(index) = HistoryHintGeometry::derive({.x = x, .y = bounds.y, .width = width, .height = bounds.height}, chrome, measured.actions[index]);
      x += width + chrome.px(action_gap);
    }

    const auto right = bounds.right() - total;

    result.facts_area = {.x = bounds.x, .y = bounds.y, .width = std::max(0.0F, right - chrome.px(facts_right_inset) - bounds.x), .height = bounds.height};
    x = result.facts_area.x;
    const auto count = std::min(measured.fact_count, measured.facts.size());

    for (std::size_t index = 0; index < count; ++index) {
      const auto width = measured.facts[index];
      if (x + width > result.facts_area.right()) {
        break;
      }

      result.facts.atMut(index) = {.x = x, .y = bounds.y, .width = width, .height = bounds.height};
      ++result.fact_count;
      x += width + chrome.px(HistoryRowGeometry::fact_gap);
    }

    return result;
  }

}
