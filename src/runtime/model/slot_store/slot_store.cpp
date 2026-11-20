module telar.runtime.model.slot_store;
import telar.base.ds;

namespace telar::runtime {

  ClientRole classifyRequest(ClientTag tag) noexcept {
    return ClientRequests::role(tag);
  }

  PaneText ExitedPanes::Record::response(const ReadPane& request) const noexcept {
    std::string_view text{bytes.view().first(length)};
    const auto last = text.find_last_not_of("\n ");

    text.remove_suffix(last == std::string_view::npos ? text.size() : text.size() - (last + 1));
    auto start = text.size();
    unsigned lines = 0;

    while (start != 0) {
      if (text[start - 1] == '\n' && ++lines == request.rows) {
        break;
      }

      --start;
    }

    text.remove_prefix(start);
    return PaneText{.request_id = request.request_id, .pane_id = pane_id, .truncated = start == 0 && truncated, .text = text, .exit_code = exit_code};
  }

  void ExitedPanes::record(std::uint64_t pane_id, std::uint64_t generation, const PaneText& text) noexcept {
    auto& entry = entries_.atMut(next_);

    entry.pane_id = pane_id;
    entry.generation = generation;
    entry.exit_code = text.exit_code.valueOr(0);
    entry.length = std::min(text.text.size(), maximum_bytes);
    entry.truncated = text.truncated || entry.length != text.text.size();
    auto kept = text.text;

    kept.remove_prefix(kept.size() - entry.length);
    std::ranges::copy(kept, entry.bytes.viewMut().begin());
    next_ = (next_ + 1) % capacity;
  }

  const ExitedPanes::Record* ExitedPanes::find(std::uint64_t pane_id, std::uint64_t generation) const noexcept {
    for (std::size_t offset = 0; offset < capacity; ++offset) {
      const auto& entry = entries_[(next_ + capacity - 1 - offset) % capacity];
      if (pane_id != 0 && entry.pane_id == pane_id && (generation == 0 || entry.generation == generation)) {
        return &entry;
      }
    }

    return nullptr;
  }

  bool HeldTabs::contains(TabLocation location) const noexcept {
    return find(location).hasValue();
  }

  bool HeldTabs::insert(TabLocation location) noexcept {
    if (contains(location)) {
      return true;
    }

    if (count_ == capacity) {
      return false;
    }

    locations_.atMut(count_++) = location;
    return true;
  }

  bool HeldTabs::erase(TabLocation location) noexcept {
    const auto index = find(location);
    if (!index) {
      return false;
    }

    locations_.atMut(*index) = locations_[--count_];
    return true;
  }

  ds::Option<TabLocation> HeldTabs::pop() noexcept {
    if (count_ == 0) {
      return ds::none;
    }

    return locations_[--count_];
  }

  ds::Option<std::size_t> HeldTabs::find(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto& candidate = locations_[index];
      if (candidate.workspace.kind == location.workspace.kind && candidate.workspace.id == location.workspace.id && candidate.tab_id == location.tab_id) {
        return index;
      }
    }

    return ds::none;
  }

  void advanceIdentityCounter(std::uint64_t& counter, std::uint64_t next) noexcept {
    // Zero marks exhaustion after the last nonzero identity; restoring an older counter must not reopen it.
    if (counter != 0) {
      counter = next == 0 ? 0 : std::max(counter, next);
    }
  }

}
