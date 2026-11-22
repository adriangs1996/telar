module telar.gui.features.monitor;

import std;

import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.wire.monitor;
import telar.base.ds;

namespace telar::gui::features::monitor {
  namespace {

    // The width of each column but the command's, in cells.
    constexpr std::uint16_t pid_cells = 7;
    constexpr std::uint16_t program_cells = 16;
    constexpr std::uint16_t tree_program_cells = 30;
    constexpr std::uint16_t threads_cells = 7;
    constexpr std::uint16_t user_cells = 9;
    constexpr std::uint16_t memory_cells = 6;
    constexpr std::uint16_t cpu_cells = 6;
    constexpr std::uint16_t owner_cells = 26;
    constexpr std::uint16_t least_command_cells = 12;
    constexpr std::uint16_t gap_cells = 1;

    constexpr std::uint64_t kibibyte = 1024;
    constexpr std::uint64_t decimal = 10;
    // Below this many units an amount keeps a decimal.
    constexpr std::uint64_t decimal_below = 100;

    constexpr std::uint32_t warm_permille = 250;
    constexpr std::uint32_t hot_permille = 800;
    constexpr double warm_fraction = 0.6;
    constexpr double hot_fraction = 0.85;

    // The longest listing a window asks for, in screens.
    constexpr std::size_t screens_asked = 3;
    // What a window asks before it knows how many rows it shows.
    constexpr std::uint16_t unknown_visible = 64;

    constexpr std::string_view guide_open = "│  ";
    constexpr std::string_view guide_blank = "   ";
    constexpr std::string_view guide_branch = "├─ ";
    constexpr std::string_view guide_last = "└─ ";
    constexpr std::string_view mark_folded = "▸ ";
    constexpr std::string_view mark_open = "▾ ";

    // Text built a piece at a time, cut at its capacity on a character's boundary.
    template <std::size_t Capacity>
    class Builder {
    public:
      void append(std::string_view text) noexcept {
        const auto piece = runtime::utf8Prefix(text, Capacity - length_);

        std::ranges::copy(piece, bytes_.viewMut().subspan(length_).begin());
        length_ += piece.size();
      }

      void repeat(std::string_view text, std::size_t times) noexcept {
        for (std::size_t index = 0; index < times; ++index) {
          append(text);
        }
      }

      [[nodiscard]] runtime::FixedText<Capacity> text() const {
        runtime::FixedText<Capacity> result;

        result.assign(std::string_view{bytes_.view().first(length_)});
        return result;
      }

    private:
      ds::Array<char, Capacity> bytes_{};
      std::size_t length_ = 0;
    };

    bool continuation(char byte) noexcept {
      return utf8::isContinuation(static_cast<std::uint8_t>(byte));
    }

    // The characters of UTF-8 text: its bytes that start one.
    std::size_t characters(std::string_view text) noexcept {
      return static_cast<std::size_t>(std::ranges::count_if(text, [](char byte) {
        return !continuation(byte);
      }));
    }

    // The first `count` characters of the text.
    std::string_view firstCharacters(std::string_view text, std::size_t count) noexcept {
      std::size_t seen = 0;

      for (std::size_t index = 0; index < text.size(); ++index) {
        if (continuation(text[index])) {
          continue;
        }

        if (seen == count) {
          text.remove_suffix(text.size() - index);
          return text;
        }

        ++seen;
      }

      return text;
    }

    template <std::size_t Capacity>
    void appendNumber(Builder<Capacity>& builder, std::uint64_t value) noexcept {
      ds::Array<char, std::numeric_limits<std::uint64_t>::digits10 + 1> digits{};
      const auto converted = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), value);

      builder.append(std::string_view{digits.view().first(static_cast<std::size_t>(converted.ptr - digits.data()))});
    }

    // A value in tenths, as a number with one decimal.
    template <std::size_t Capacity>
    void appendTenths(Builder<Capacity>& builder, std::uint64_t tenths) noexcept {
      appendNumber(builder, tenths / decimal);
      builder.append(".");
      appendNumber(builder, tenths % decimal);
    }

    // The guide a tree draws at a level of a row's path.
    std::string_view guide(bool own, bool goes_on) noexcept {
      if (own) {
        return goes_on ? guide_branch : guide_last;
      }

      return goes_on ? guide_open : guide_blank;
    }

  }

  Columns columns(std::uint16_t cells, MonitorLayout layout) noexcept {
    const auto program = layout == MonitorLayout::tree ? tree_program_cells : program_cells;
    const ds::Array<std::uint16_t, column_count> widths{pid_cells, program, 0, threads_cells, user_cells, memory_cells, cpu_cells, owner_cells};
    const ds::Array<bool, column_count> right{true, false, false, true, false, true, true, false};
    std::uint32_t fixed = gap_cells * (column_count - 1);

    for (const auto width : widths) {
      fixed += width;
    }

    const auto command = static_cast<std::uint16_t>(std::max<std::int64_t>(least_command_cells, std::int64_t{cells} - fixed));
    Columns result{};
    std::uint16_t start = 0;

    for (std::size_t index = 0; index < column_count; ++index) {
      const auto width = index == static_cast<std::size_t>(Column::command) ? command : widths[index];

      result.atMut(index) = {.column = static_cast<Column>(index), .start = start, .cells = width, .right = right[index]};
      start = static_cast<std::uint16_t>(start + width + gap_cells);
    }

    return result;
  }

  CellText fit(std::string_view text, std::uint16_t cells, bool right, std::string_view mark) {
    Builder<cell_text_bytes> builder;
    const auto length = characters(text);

    if (length > cells) {
      const auto mark_length = std::min<std::size_t>(characters(mark), cells);

      builder.append(firstCharacters(text, cells - mark_length));
      builder.append(firstCharacters(mark, mark_length));
      return builder.text();
    }

    if (right) {
      builder.repeat(" ", cells - length);
    }

    builder.append(text);
    return builder.text();
  }

  ShortText bytes(std::uint64_t value) {
    constexpr ds::Array<std::string_view, 5> units{"B", "K", "M", "G", "T"};
    Builder<short_text_bytes> builder;
    std::size_t unit = 0;
    // In tenths of the unit, so the decimal survives the divisions.
    auto tenths = value * decimal;

    while (tenths >= kibibyte * decimal && unit + 1 < units.size()) {
      tenths /= kibibyte;
      ++unit;
    }

    if (unit == 0 || tenths >= decimal_below * decimal) {
      appendNumber(builder, (tenths + (decimal / 2)) / decimal);
    } else {
      appendTenths(builder, tenths);
    }

    builder.append(units[unit]);
    return builder.text();
  }

  ShortText percent(std::uint32_t permille) {
    Builder<short_text_bytes> builder;

    appendTenths(builder, permille);
    return builder.text();
  }

  Tone cpuTone(std::uint32_t permille) noexcept {
    if (permille >= hot_permille) {
      return Tone::hot;
    }

    return permille >= warm_permille ? Tone::warm : Tone::normal;
  }

  Tone meterTone(double fraction) noexcept {
    if (fraction > hot_fraction) {
      return Tone::hot;
    }

    return fraction > warm_fraction ? Tone::warm : Tone::normal;
  }

  CellText treePrefix(const TreePlace& place) {
    Builder<cell_text_bytes> builder;
    const auto levels = std::min<std::size_t>(place.depth, MonitorLimits::guide_levels);

    for (std::size_t level = 0; level < levels; ++level) {
      builder.append(guide(level + 1 == place.depth, (place.guides & (std::uint32_t{1} << level)) != 0));
    }

    // Past the levels with guides, a level is still a step to the right.
    builder.repeat(guide_blank, place.depth - levels);
    if (place.folded > 0) {
      builder.append(mark_folded);
    } else if (place.children > 0) {
      builder.append(mark_open);
    }

    return builder.text();
  }

  CellText abbreviateHome(std::string_view command, std::string_view home) {
    Builder<cell_text_bytes> builder;

    if (home.empty() || home == "/") {
      builder.append(command);
      return builder.text();
    }

    std::size_t position = 0;

    while (position < command.size()) {
      const auto found = command.find(home, position);
      const auto end = found == std::string_view::npos ? std::string_view::npos : found + home.size();
      // Only a whole directory: at the start of a word, and followed by a slash or the word's end.
      const auto starts_word = found != std::string_view::npos && (found == 0 || command[found - 1] == ' ' || command[found - 1] == '=');
      const auto ends_directory = end != std::string_view::npos && (end == command.size() || command[end] == '/' || command[end] == ' ');

      if (found == std::string_view::npos) {
        builder.append(command.substr(position));
        break;
      }

      builder.append(command.substr(position, found - position));
      builder.append(starts_word && ends_directory ? "~" : home);
      position = end;
    }

    return builder.text();
  }

  CellText ownerText(ProcessOwner owner, std::string_view name) {
    Builder<cell_text_bytes> builder;
    const auto named = [&](std::string_view kind) {
      builder.append(kind);
      if (!name.empty()) {
        builder.append(" · ");
        builder.append(name);
      }
    };

    switch (owner) {
    case ProcessOwner::none:
      builder.append("·");
      break;
    case ProcessOwner::telar:
      builder.append("telar");
      break;
    case ProcessOwner::pane:
      named("pane");
      break;
    case ProcessOwner::agent:
      named("agent");
      break;
    case ProcessOwner::agent_child:
      named("↳ agent");
      break;
    }

    return builder.text();
  }

  std::size_t rowCount(std::uint32_t matched, std::span<const GroupRow> groups, MonitorLayout layout) noexcept {
    return layout == MonitorLayout::owner ? matched + groups.size() : matched;
  }

  Slot slotAt(std::size_t row, std::span<const GroupRow> groups, MonitorLayout layout) noexcept {
    if (layout != MonitorLayout::owner) {
      return {.index = row};
    }

    std::size_t processes = 0;

    for (std::size_t group = 0; group < groups.size(); ++group) {
      if (row == 0) {
        return {.group = true, .index = group};
      }

      --row;
      if (row < groups[group].processes) {
        return {.index = processes + row};
      }

      row -= groups[group].processes;
      processes += groups[group].processes;
    }

    return {.index = processes + row};
  }

  std::size_t rowOf(std::size_t process, std::span<const GroupRow> groups, MonitorLayout layout) noexcept {
    if (layout != MonitorLayout::owner) {
      return process;
    }

    std::size_t before = 0;
    std::size_t titles = 0;

    for (const auto& group : groups) {
      ++titles;
      if (process < before + group.processes) {
        break;
      }

      before += group.processes;
    }

    return process + titles;
  }

  Window windowAround(std::size_t first, std::uint16_t visible, std::span<const GroupRow> groups, MonitorLayout layout) noexcept {
    const auto shown = visible == 0 ? unknown_visible : visible;
    const auto slot = slotAt(first, groups, layout);
    std::size_t process = slot.index;

    // A group's title stands before its first process.
    if (slot.group) {
      process = 0;
      for (std::size_t group = 0; group < slot.index; ++group) {
        process += groups[group].processes;
      }
    }

    const auto offset = process > shown ? process - shown : 0;
    const auto limit = std::min<std::size_t>(shown * screens_asked, MonitorLimits::maximum_processes);

    return {.offset = static_cast<std::uint32_t>(offset), .limit = static_cast<std::uint16_t>(limit)};
  }

}
