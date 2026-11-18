module telar.gui.features.bindings;

import std;

import telar.gui.foundation.keys;
import telar.base.ds;

namespace telar::gui::features::bindings {

  ds::Option<KeyLeases::Owner> KeyLeases::owner(std::uint64_t physical) const noexcept {
    const auto index = find(physical);
    if (index == count_) {
      return ds::none;
    }

    return leases_[index].owner;
  }

  bool KeyLeases::acquire(std::uint64_t physical) noexcept {
    auto index = find(physical);
    if (index == count_) {
      if (count_ == leases_.size()) {
        ++overflow_;

        return false;
      }

      index = count_++;
    }

    leases_[index] = {.physical = physical, .owner = Owner::binding};

    return true;
  }

  void KeyLeases::transfer(std::uint64_t physical) noexcept {
    const auto index = find(physical);
    if (index != count_) {
      leases_[index].owner = Owner::application;
    }
  }

  ds::Option<KeyLeases::Owner> KeyLeases::release(std::uint64_t physical) noexcept {
    const auto index = find(physical);
    if (index == count_) {
      return ds::none;
    }

    const auto owner = leases_[index].owner;

    leases_[index] = leases_[--count_];

    return owner;
  }

  void KeyLeases::clear() noexcept {
    count_ = 0;
  }

  std::uint64_t KeyLeases::overflowCount() const noexcept {
    return overflow_;
  }

  // Physical key 0 is no key, so it is never held.
  std::size_t KeyLeases::find(std::uint64_t physical) const noexcept {
    const auto held = std::span{leases_}.first(count_);
    const auto found = std::ranges::find(held, physical, &Lease::physical);

    return physical == 0 ? count_ : static_cast<std::size_t>(found - held.begin());
  }

}
