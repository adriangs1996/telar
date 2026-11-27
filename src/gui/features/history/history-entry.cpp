module telar.gui.features.history;

import std;

import telar.wire.vocabulary;

namespace telar::gui::features::history {

  bool HistoryChip::operator==(const HistoryChip& other) const noexcept {
    return key == other.key && value.view() == other.value.view();
  }

  std::span<const HistoryChip> HistoryChips::view() const noexcept {
    return std::span{chips_}.first(count_);
  }

  ds::Option<std::string_view> HistoryChips::value(HistoryFilterKey key) const noexcept {
    for (const auto& chip : view()) {
      if (chip.key == key) {
        return chip.value.view();
      }
    }

    return {};
  }

  bool HistoryChips::set(HistoryFilterKey key, std::string_view value) {
    if (value.empty() || value.size() > HistoryChip::value_capacity) {
      return false;
    }

    std::size_t index = 0;

    while (index < count_ && chips_[index].key != key) {
      ++index;
    }

    if (index == capacity) {
      return false;
    }

    auto& chip = chips_.atMut(index);

    count_ = std::max(count_, index + 1);
    chip.key = key;
    chip.value.truncate(0);
    chip.value.append(value);

    return true;
  }

  bool HistoryChips::remove(std::size_t index) noexcept {
    if (index >= count_) {
      return false;
    }

    for (auto next = index + 1; next < count_; ++next) {
      chips_.atMut(next - 1) = chips_[next];
    }

    --count_;

    return true;
  }

  std::span<const HistoryRange> HistoryMarks::view() const noexcept {
    return std::span{ranges_}.first(count_);
  }

  void HistoryMarks::assign(std::span<const HistoryRange> ranges) noexcept {
    count_ = std::min(ranges.size(), capacity);
    std::ranges::copy(ranges.first(count_), ranges_.viewMut().begin());
  }

  bool HistoryMarks::operator==(const HistoryMarks& other) const noexcept {
    return std::ranges::equal(view(), other.view(), [](HistoryRange left, HistoryRange right) {
      return left.start == right.start && left.end == right.end;
    });
  }

  bool HistoryChips::operator==(const HistoryChips& other) const noexcept {
    return std::ranges::equal(view(), other.view());
  }

  void HistoryText::validate(std::string_view text, bool bracketed_paste) {
    if (text.empty() || text.size() > maximum_bytes) {
      throw EncodingError{"Command is empty or exceeds its input capacity"};
    }

    validateUtf8(text);
    for (std::size_t index = 0; index < text.size(); ++index) {
      const auto byte = static_cast<Byte>(text[index]);
      if (byte == '\n' || byte == '\t') {
        if (!bracketed_paste) {
          throw EncodingError{"Multiline/tab paste requires shell bracketed-paste support"};
        }

        continue;
      }

      if (isControl(text, index)) {
        throw EncodingError{"Command contains terminal controls; cannot paste"};
      }
    }
  }

  bool HistoryText::isControl(std::string_view text, std::size_t index) noexcept {
    constexpr Byte first_printable = 0x20;
    constexpr Byte delete_control = 0x7f;
    constexpr Byte extended_control_lead = 0xc2;
    constexpr Byte first_extended_control = 0x80;
    constexpr Byte last_extended_control = 0x9f;
    const auto byte = static_cast<Byte>(text[index]);
    if (byte < first_printable || byte == delete_control) {
      return true;
    }

    if (byte != extended_control_lead || index + 1 == text.size()) {
      return false;
    }

    const auto next = static_cast<Byte>(text[index + 1]);

    return next >= first_extended_control && next <= last_extended_control;
  }

}
