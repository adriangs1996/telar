module telar.gui.features.terminal.filter;

import std;

import telar.base.text.pattern;
import telar.base.text.utf8;
import telar.base.memory.allocators;

namespace telar::gui::features::terminal::filter {

  Lines::Held::Held(Memory& memory)
      : text(memory) {}

  Lines::Shown::Shown(Memory& memory)
      : runs(memory),
        text(memory) {}

  Lines::Lines(Memory& memory)
      : line_(memory),
        held_(memory),
        shown_(memory) {}

  void Lines::reset(std::size_t context, bool invert) noexcept {
    context_ = std::min(context, maximum_context);
    invert_ = invert;
    reading_ = false;
    line_.clear();
    held_.count = 0;
    held_.text.clear();
    after_ = 0;
    shown_.runs.clear();
    shown_.text.clear();
    shown_.matches = 0;
    shown_.truncated = false;
  }

  void Lines::follow(const Lines& other) {
    context_ = other.context_;
    invert_ = other.invert_;
    line_first_ = other.line_first_;
    line_end_ = other.line_end_;
    reading_ = other.reading_;
    line_.assign(other.line_.view());
    held_.lines = other.held_.lines;
    held_.count = other.held_.count;
    held_.text.assign(other.held_.text.view());
    after_ = other.after_;
    shown_.runs.clear();
    shown_.text.clear();
    shown_.matches = 0;
    shown_.truncated = false;
  }

  void Lines::feed(runtime::Pattern& pattern, std::uint64_t row, std::string_view text, bool wraps) {
    if (!reading_) {
      reading_ = true;
      line_first_ = row;
      line_.clear();
    }

    line_end_ = row + 1;
    if (line_.size() < maximum_line_bytes) {
      line_.append(runtime::utf8Prefix(text, maximum_line_bytes - line_.size()));
    }

    if (!wraps) {
      finish(pattern);
    }
  }

  void Lines::finish(runtime::Pattern& pattern) {
    reading_ = false;

    // A row is as wide as the screen: the spaces after its text are the screen's, not the line's.
    auto line = line_.view();

    while (!line.empty() && line.back() == ' ') {
      line.remove_suffix(1);
    }

    const bool kept = pattern.matches(line) != invert_;

    if (kept) {
      ++shown_.matches;
      release(held_, shown_);
      show(shown_, line_first_, line_end_, line);
      after_ = context_;
    } else if (after_ != 0) {
      --after_;
      show(shown_, line_first_, line_end_, line);
    } else if (context_ != 0) {
      hold(held_, context_, line_first_, line_end_, line);
    }
  }

  void Lines::show(Shown& shown, std::uint64_t first, std::uint64_t end, std::string_view line) {
    if (shown.truncated) {
      return;
    }

    auto& runs = shown.runs;

    if (!runs.empty() && runs[runs.size() - 1].end == first) {
      runs.atMut(runs.size() - 1).end = end;
    } else if (runs.size() < maximum_runs) {
      runs.push(ShownRun{.first = first, .end = end});
    } else {
      shown.truncated = true;
      return;
    }

    if (shown.text.size() + line.size() + 1 > maximum_text_bytes) {
      shown.truncated = true;
      return;
    }

    shown.text.append(line);
    shown.text.append("\n");
  }

  void Lines::hold(Held& held, std::size_t context, std::uint64_t first, std::uint64_t end, std::string_view line) {
    // The oldest held line gives way: only the last `context` can be a match's context.
    if (held.count == context) {
      const auto dropped = held.lines[0].length;

      held.text.remove(0, dropped);
      std::ranges::shift_left(held.lines.viewMut().first(held.count), 1);
      --held.count;
      for (auto& kept : held.lines.viewMut().first(held.count)) {
        kept.offset -= dropped;
      }
    }

    held.lines.atMut(held.count++) = HeldLine{.first = first, .end = end, .offset = held.text.size(), .length = line.size()};
    held.text.append(line);
  }

  void Lines::release(Held& held, Shown& shown) {
    for (const auto& line : held.lines.view().first(held.count)) {
      show(shown, line.first, line.end, held.text.view().substr(line.offset, line.length));
    }

    held.count = 0;
    held.text.clear();
  }

  std::span<const ShownRun> Lines::runs() const noexcept {
    return shown_.runs.view();
  }

  std::string_view Lines::text() const noexcept {
    return shown_.text.view();
  }

  std::size_t Lines::matches() const noexcept {
    return shown_.matches;
  }

  bool Lines::truncated() const noexcept {
    return shown_.truncated;
  }

}
