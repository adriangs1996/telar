module telar.gui.features.status_bar;

import std;
import telar.tbc;

namespace telar::gui::features::status_bar {

  void CpuHistory::push(std::uint8_t percent) noexcept {
    samples_[next_] = percent;
    next_ = (next_ + 1) % capacity;
    count_ = count_ < capacity ? count_ + 1 : capacity;
  }

  tbc::view<std::span<const std::uint8_t>, tbc::lt::a> CpuHistory::ordered(tbc::view<Samples&, tbc::lt::a> buffer) const noexcept {
    const auto start = (next_ + capacity - count_) % capacity;

    for (std::size_t index = 0; index < count_; ++index) {
      buffer[index] = samples_[(start + index) % capacity];
    }

    return std::span{buffer}.first(count_);
  }

}
