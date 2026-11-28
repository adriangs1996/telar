module telar.gui.features.history;

import std;

import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::gui::features::history {

  HistoryPins::HistoryPins(Memory& memory)
      : text_(memory) {}

  bool HistoryPins::toggle(std::string_view command) {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto removed = pins_[index];
      if (std::string_view{text_}.substr(removed.offset, removed.length) != command) {
        continue;
      }

      // The text after the pin's moves back over it.

      text_.remove(removed.offset, removed.length);
      for (auto next = index + 1; next < count_; ++next) {
        auto moved = pins_[next];

        moved.offset -= removed.length;
        pins_.atMut(next - 1) = moved;
      }

      --count_;

      return false;
    }

    if (command.empty() || command.size() > maximum_command_bytes || count_ == capacity) {
      throw std::length_error{"No more commands can be pinned"};
    }

    append(command);

    return true;
  }

  bool HistoryPins::pinned(std::string_view command) const {
    for (std::size_t index = 0; index < count_; ++index) {
      if (at(index) == command) {
        return true;
      }
    }

    return false;
  }

  std::size_t HistoryPins::count() const noexcept {
    return count_;
  }

  std::string_view HistoryPins::at(std::size_t index) const {
    // The newest pin is the last appended.
    if (index >= count_) {
      return {};
    }

    const auto pin = pins_[count_ - 1 - index];

    return std::string_view{text_}.substr(pin.offset, pin.length);
  }

  void HistoryPins::write(ds::String<Memory>& destination) const {
    destination.clear();
    // Oldest first, so reading them appends them in the order they were pinned.
    for (std::size_t index = count_; index-- > 0;) {
      for (const auto character : at(index)) {
        if (character == '\\') {
          destination.append("\\\\");
        } else if (character == '\n') {
          destination.append("\\n");
        } else {
          destination.append(std::string_view{&character, 1});
        }
      }

      destination.append("\n");
    }
  }

  void HistoryPins::read(std::string_view source) {
    count_ = 0;
    text_.clear();
    ds::String<Memory> line{text_.memory()};

    while (!source.empty() && count_ < capacity) {
      const auto end = std::min(source.find('\n'), source.size());

      line.clear();
      for (std::size_t index = 0; index < end; ++index) {
        if (source[index] == '\\' && index + 1 < end) {
          ++index;
          line.append(source[index] == 'n' ? std::string_view{"\n"} : source.substr(index, 1));
        } else {
          line.append(source.substr(index, 1));
        }
      }

      if (!line.empty() && line.size() <= maximum_command_bytes && !pinned(line)) {
        append(line);
      }

      source.remove_prefix(std::min(end + 1, source.size()));
    }
  }

  void HistoryPins::append(std::string_view command) {
    pins_.atMut(count_) = {.offset = text_.size(), .length = command.size()};
    text_.append(command);
    ++count_;
  }

}
