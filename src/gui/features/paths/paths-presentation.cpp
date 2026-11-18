module telar.gui.features.paths;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.base.ds;

namespace telar::gui::features::paths {

  PathInsertion::AbsolutePath PathInsertion::join(JoinParts parts) {
    AbsolutePath path;

    path.append(parts.root);
    if (parts.root.size() != 1) {
      path.append("/");
    }

    path.append(parts.relative);

    return path;
  }

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> PathInsertion::relativeTo(std::string_view anchor, tbc::view<std::string_view, tbc::lt::a> path) noexcept {
    if (anchor.size() == 1) {
      if (path.size() <= 1) {
        return ds::none;
      }

      path.remove_prefix(1);

      return path;
    }

    if (path.size() <= anchor.size() + 1 || !path.starts_with(anchor) || path[anchor.size()] != '/') {
      return ds::none;
    }

    path.remove_prefix(anchor.size() + 1);

    return path;
  }

  ds::Option<PathInsertion::Quoted> PathInsertion::quote(std::string_view word) {
    Quoted output;

    if (word.empty()) {
      return output;
    }

    try {
      if (word.front() == '-') {
        output.append("./");
      }

      if (plain(word)) {
        output.append(word);

        return output;
      }

      output.append("'");
      for (const auto byte : word) {
        if (byte == '\'') {
          output.append("'\\''");
        } else {
          output.append(std::string_view{&byte, 1});
        }
      }

      output.append("'");
    } catch (const std::length_error&) {
      return ds::none;
    }

    return output;
  }

  ds::Option<PathInsertion::Text> PathInsertion::prepare(const PathPickerPage& page, Choice choice) {
    if (page.matches().empty()) {
      return ds::none;
    }

    const auto& match = page.matches()[std::min(choice.selection, page.matches().size() - 1)];
    const auto full = join({.root = page.root(), .relative = page.path(match)});
    auto word = full.view();

    if (!choice.absolute) {
      if (const auto relative = relativeTo(page.anchor(), word)) {
        word = *relative;
      }
    }

    const auto quoted = quote(word);
    if (!quoted) {
      return ds::none;
    }

    return PasteEncoding::encode<PathPickerLimits::quoted_bytes>(quoted->view(), choice.bracketed);
  }

  bool PathInsertion::plain(std::string_view word) noexcept {
    return std::ranges::all_of(word, [](char byte) {
      constexpr std::string_view literal_punctuation = "_-./+@%,:";
      const auto letter = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
      const auto digit = byte >= '0' && byte <= '9';

      return letter || digit || literal_punctuation.contains(byte);
    });
  }

  void PathLabel::layout(tbc::view<std::string_view, tbc::lt::a> path, std::span<const std::uint16_t> positions, std::uint16_t width) {
    count_ = 0;
    const auto name_start = nameStart(path);

    if (cellTextColumns(path) <= width) {
      appendSpan({.path = path, .positions = positions, .end = path.size(), .name_start = name_start});

      return;
    }

    const auto name_width = cellTextColumns(path.substr(name_start));
    const auto head_width = width > name_width + ellipsis_columns ? width - name_width - ellipsis_columns : 0;
    const auto head_end = fitting(path.substr(0, name_start), head_width);

    appendSpan({.path = path, .positions = positions, .end = head_end, .name_start = name_start});
    push({.text = ellipsis, .tone = PathLabelTone::ellipsis});
    appendSpan({.path = path, .positions = positions, .start = name_start, .end = path.size(), .name_start = name_start});
  }

  tbc::view<std::span<const PathLabelRun>, tbc::lt::a> PathLabel::runs() const noexcept {
    return std::span{runs_}.first(count_);
  }

  std::size_t PathLabel::nameStart(std::string_view path) noexcept {
    const auto last = path.find_last_not_of('/');

    path.remove_suffix(last == std::string_view::npos ? path.size() : path.size() - last - 1);
    const auto split = path.rfind('/');

    return split == std::string_view::npos ? 0 : split + 1;
  }

  std::size_t PathLabel::nextScalar(std::string_view text, std::size_t offset) noexcept {
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[offset]));
    const auto length = sequence >= 1 && sequence <= Utf8Scalar::leading_masks.size() ? sequence : 1;

    return std::min(offset + length, text.size());
  }

  std::size_t PathLabel::fitting(std::string_view text, std::uint32_t width) {
    std::uint32_t used = 0;
    std::size_t end = 0;

    while (end < text.size()) {
      const auto next = nextScalar(text, end);
      const auto columns = cellTextColumns(text.substr(end, next - end));
      if (used + columns > width) {
        break;
      }

      used += columns;
      end = next;
    }

    return end;
  }

  PathLabelTone PathLabel::toneAt(const Span& span, std::size_t first, std::size_t last) noexcept {
    for (const auto position : span.positions) {
      if (position >= first && position < last) {
        return PathLabelTone::match;
      }
    }

    return first >= span.name_start ? PathLabelTone::name : PathLabelTone::directory;
  }

  void PathLabel::appendSpan(tbc::view<Span, tbc::lt::a> span) {
    if (span.start == span.end) {
      return;
    }

    auto run_start = span.start;
    auto tone = toneAt(span, span.start, nextScalar(span.path, span.start));
    auto cursor = span.start;

    while (cursor < span.end) {
      const auto next = nextScalar(span.path, cursor);
      const auto current = toneAt(span, cursor, next);
      if (current != tone) {
        push({.text = span.path.substr(run_start, cursor - run_start), .tone = tone});
        run_start = cursor;
        tone = current;
      }

      cursor = next;
    }

    push({.text = span.path.substr(run_start, span.end - run_start), .tone = tone});
  }

  void PathLabel::push(tbc::view<PathLabelRun, tbc::lt::a> run) noexcept {
    if (count_ < runs_.size()) {
      runs_[count_++] = run;
    }
  }

  std::string_view PathPickerLabels::root(std::string_view path) noexcept {
    if (path.size() <= 1) {
      return "/";
    }

    const auto split = path.rfind('/');
    if (split != std::string_view::npos) {
      path.remove_prefix(split + 1);
    }

    return path;
  }

  PathPickerLabels::Count PathPickerLabels::count(const PathPickerPage& page) {
    Count result;

    result.appendDecimal(page.matches().size());
    result.append(" of ");
    result.appendDecimal(page.scanned());

    return result;
  }

  PathPickerLabels::Status PathPickerLabels::status(const PathPickerPage& page) {
    Status result;

    if (page.phase() == PathPickerPhase::failed) {
      result.append(page.error());

      return result;
    }

    if (!page.complete()) {
      result.append("indexing · ");
      result.appendDecimal(page.scanned());
    } else {
      result.appendDecimal(page.scanned());
      result.append(page.truncated() ? "+ paths" : " paths");
    }

    return result;
  }

  std::string_view PathPickerLabels::empty(const PathPickerPage& page) noexcept {
    if (page.phase() == PathPickerPhase::failed) {
      return "No paths";
    }

    return page.phase() == PathPickerPhase::ready && page.complete() ? "No paths match" : "Searching…";
  }

  PathPickerPlacement PathPickerPlacement::forPage(CellRectangle host, ds::Option<CellPosition> cursor, std::uint16_t count) noexcept {
    const auto rows = std::max<std::uint16_t>(1, std::min(count, maximum_rows));

    return place(host, cursor, maximum_width, static_cast<std::uint16_t>(rows + chrome_rows));
  }

  PathPickerPlacement PathPickerPlacement::place(CellRectangle host, ds::Option<CellPosition> cursor, std::uint16_t requested_width, std::uint16_t requested_height) noexcept {
    const auto width = std::min(requested_width, host.width);
    const auto height = std::min(requested_height, host.height);

    if (!cursor) {
      return {.area = {.x = static_cast<std::uint16_t>(host.x + ((host.width - width) / 2)), .y = static_cast<std::uint16_t>(host.y + ((host.height - height) / fallback_vertical_divisor)), .width = width, .height = height}};
    }

    const auto left = cursor->x > cursor_inset ? cursor->x - cursor_inset : 0;
    const auto x = std::min<unsigned>(left, host.x + host.width - width);
    const auto host_bottom = static_cast<unsigned>(host.y) + host.height;
    const auto next_row = static_cast<unsigned>(cursor->y) + 1;
    const auto below = host_bottom > next_row ? host_bottom - next_row : 0;
    const auto above = cursor->y > host.y ? cursor->y - host.y : 0;
    const auto flipped = below < height && above > below;
    const auto room = flipped ? above : below;
    const auto fitted = static_cast<std::uint16_t>(std::min<unsigned>(height, room));

    return {
        .area = {.x = static_cast<std::uint16_t>(std::max<unsigned>(x, host.x)), .y = static_cast<std::uint16_t>(flipped ? cursor->y - fitted : next_row), .width = width, .height = fitted},
        .flipped = flipped,
    };
  }

  PathPickerGeometry PathPickerGeometry::measure(PathPickerPlacement placement, std::size_t total, std::size_t selection, PathPickerFieldColumns columns) noexcept {
    PathPickerGeometry result;
    const auto content = placement.area.inner(1);
    constexpr std::uint16_t field_and_footer_rows = 2;
    if (content.height <= field_and_footer_rows) {
      return result;
    }

    auto field = content;

    field.y = placement.flipped ? static_cast<std::uint16_t>(content.y + content.height - 1) : content.y;
    field.height = 1;
    result.footer = field;
    result.footer.y = placement.flipped ? content.y : static_cast<std::uint16_t>(content.y + content.height - 1);
    const auto count_columns = std::min<std::uint16_t>(columns.count, field.width / 4);
    const auto count_room = std::min<std::uint16_t>(field.width, static_cast<std::uint16_t>(count_columns + 1));
    const auto field_columns = static_cast<std::uint16_t>(field.width - count_room);
    const auto count_inset = std::min<std::uint16_t>(1, count_room);

    result.count_label = {.x = static_cast<std::uint16_t>(field.x + field_columns + count_inset), .y = field.y, .width = static_cast<std::uint16_t>(count_room - count_inset), .height = 1};
    const auto root_columns = std::min<std::uint16_t>(static_cast<std::uint16_t>(columns.root + 1), field_columns / 2);

    result.root_label = {.x = field.x, .y = field.y, .width = root_columns, .height = 1};
    result.query = {.x = static_cast<std::uint16_t>(field.x + root_columns), .y = field.y, .width = static_cast<std::uint16_t>(field_columns - root_columns), .height = 1};

    const auto row_area = CellRectangle{.x = content.x, .y = static_cast<std::uint16_t>(content.y + 1), .width = content.width, .height = static_cast<std::uint16_t>(content.height - field_and_footer_rows)};
    const auto count = std::min<std::size_t>({row_area.height, total, result.rows.size()});
    const auto selected = total == 0 ? 0 : std::min(selection, total - 1);
    const auto first = selected + 1 > count ? selected + 1 - count : 0;

    result.empty = {.x = static_cast<std::uint16_t>(row_area.x + std::min<std::uint16_t>(2, row_area.width)), .y = placement.flipped ? static_cast<std::uint16_t>(row_area.y + row_area.height - 1) : row_area.y, .width = static_cast<std::uint16_t>(row_area.width - std::min<std::uint16_t>(2, row_area.width)), .height = 1};
    for (std::size_t offset = 0; offset < count; ++offset) {
      const auto row = placement.flipped ? row_area.height - 1 - offset : offset;

      result.rows[offset] = {.bounds = {.x = row_area.x, .y = static_cast<std::uint16_t>(row_area.y + row), .width = row_area.width, .height = 1}, .index = first + offset};
    }

    result.row_count = count;

    return result;
  }

}
