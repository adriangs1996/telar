module telar.gui.features.prompt;

import std;

import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  namespace {

    // Whether `command` goes on from `typed`, as a suggestion shows the rest of it.
    bool extends(std::string_view command, std::string_view typed) noexcept {
      return command.size() > typed.size() && command.starts_with(typed);
    }

    // How close a command ran to where the line is: the same directory, the same workspace, or
    // anywhere; the pane's own before others within each. Lower is closer.
    struct Closeness {
      std::uint8_t where = 0;
      bool other_pane = false;

      [[nodiscard]] auto operator<=>(const Closeness&) const = default;
    };

  }

  Walk::Walk(tbc::mut_a<Memory> memory)
      : bytes_(memory),
        ends_(memory) {}

  void Walk::clear() noexcept {
    bytes_.clear();
    ends_.clear();
  }

  void Walk::push(std::string_view command) {
    bytes_.append(command);
    ends_.push(static_cast<std::uint32_t>(bytes_.size()));
  }

  std::size_t Walk::size() const noexcept {
    return ends_.size();
  }

  bool Walk::empty() const noexcept {
    return ends_.empty();
  }

  std::string_view Walk::operator[](std::size_t index) const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the bytes, which cannot throw
    const auto begin = index == 0 ? 0 : ends_[index - 1];

    return bytes_.view().substr(begin, ends_[index] - begin);
  }

  std::string_view Recall::Entry::command() const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    return text.view().substr(0, command_end);
  }

  std::string_view Recall::Entry::directory() const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    return text.view().substr(command_end, directory_end - command_end);
  }

  std::string_view Recall::Entry::workspace() const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    return text.view().substr(directory_end);
  }

  Recall::Recall(tbc::mut_a<Memory> memory)
      : memory_(memory),
        entries_(memory) {}

  std::size_t Recall::size() const noexcept {
    return entries_.size();
  }

  bool Recall::empty() const noexcept {
    return entries_.empty();
  }

  std::string_view Recall::command(std::size_t index) const noexcept {
    return entries_[index].command();
  }

  std::uint64_t Recall::revision() const noexcept {
    return revision_;
  }

  tbc::val_a<Recall::Entry> Recall::entry(std::string_view command, const Place& place, bool failed) const {
    ds::String<Memory> text{memory_};

    text.reserve(command.size() + place.directory.size() + place.workspace.size());
    text.append(command);
    text.append(place.directory);
    text.append(place.workspace);
    return Entry{
        .text = std::move(text),
        .command_end = static_cast<std::uint32_t>(command.size()),
        .directory_end = static_cast<std::uint32_t>(command.size() + place.directory.size()),
        .pane_id = place.pane_id,
        .failed = failed,
    };
  }

  void Recall::remember(std::string_view command, const Place& place) {
    // Made first: `command` may be one of the entries the list drops.
    auto made = entry(command, place, false);

    static_cast<void>(entries_.retain([&made](const Entry& kept) {
      return kept.command() != made.command();
    }));

    entries_.insert(0, std::move(made));
    entries_.truncate(capacity);
    ++revision_;
  }

  void Recall::ended(std::uint64_t pane_id, bool failed) noexcept {
    for (auto& entry : entries_.viewMut()) {
      if (entry.pane_id == pane_id) {
        entry.failed = failed;
        ++revision_;
        return;
      }
    }
  }

  void Recall::clear() noexcept {
    entries_.clear();
    ++revision_;
  }

  bool Recall::add(std::string_view command, const Place& place, bool failed) {
    if (entries_.size() >= capacity) {
      return false;
    }

    entries_.push(entry(command, place, failed));
    ++revision_;
    return true;
  }

  bool Recall::failed(std::string_view command) const noexcept {
    const auto* found = std::ranges::find_if(entries_, [command](const Entry& entry) {
      return entry.command() == command;
    });

    return found != entries_.end() && found->failed;
  }

  Suggested Recall::suggest(History own, std::string_view typed, const Place& place) const noexcept {
    // The closest there is: the same directory and pane.
    constexpr Closeness closest{};
    constexpr std::uint8_t same_workspace = 1;
    constexpr std::uint8_t anywhere = 2;
    ds::Option<Closeness> best;
    Suggested suggested;

    for (std::size_t index = 0; index < entries_.size(); ++index) {
      const auto& entry = entries_[index];
      if (entry.failed || !extends(entry.command(), typed)) {
        continue;
      }

      std::uint8_t where = anywhere;

      if (!place.directory.empty() && entry.directory() == place.directory) {
        where = 0;
      } else if (!place.workspace.empty() && entry.workspace() == place.workspace) {
        where = same_workspace;
      }

      const Closeness closeness{.where = where, .other_pane = entry.pane_id != place.pane_id};
      if (!best || closeness < *best) {
        best = closeness;
        suggested = {.source = Suggested::Source::recall, .index = index};
        if (closeness == closest) {
          break;
        }
      }
    }

    for (std::size_t index = own.size(); !best && index-- > 0;) {
      if (extends(own[index].view(), typed) && !failed(own[index].view())) {
        suggested = {.source = Suggested::Source::own, .index = index};
        break;
      }
    }

    return suggested;
  }

  void Recall::walk(Walk& out, History own, std::string_view prefix, const Place& place, UpScope scope) const {
    // The commands taken so far, as views of `own` and the entries, which stay while it runs.
    ds::Map<std::string_view, bool, Memory> taken{memory_};

    out.clear();

    const auto take = [&](std::string_view command) {
      if (command.starts_with(prefix) && command != prefix && !taken.contains(command)) {
        static_cast<void>(taken.insert(command, true));
        out.push(command);
      }
    };

    for (std::size_t index = own.size(); index-- > 0;) {
      take(own[index].view());
    }

    for (const auto& entry : entries_) {
      if (entry.pane_id == place.pane_id) {
        take(entry.command());
      }
    }

    if (scope == UpScope::pane) {
      return;
    }

    if (!place.workspace.empty()) {
      for (const auto& entry : entries_) {
        if (entry.workspace() == place.workspace) {
          take(entry.command());
        }
      }
    }

    if (scope == UpScope::workspace) {
      return;
    }

    for (const auto& entry : entries_) {
      take(entry.command());
    }
  }

}
