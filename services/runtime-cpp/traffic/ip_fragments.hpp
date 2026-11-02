#pragma once

#include "network_packet.hpp"
#include "../memory/sensitive_allocation.hpp"
#include <algorithm>
#include <chrono>
#include <optional>

namespace telar::runtime::traffic {

template <Allocator Memory>
class IpFragments {
  using Clock = std::chrono::steady_clock;
  struct Key {
    std::uint64_t session = 0;
    std::uint32_t interface = 0;
    std::uint32_t link_type = 0;
    std::array<char, Limits::interface_bytes> name{};
    std::array<Byte, 32> addresses{};
    std::uint32_t identification = 0;
    Byte protocol = 0;
    bool ipv6 = false;
    bool operator==(const Key &) const = default;
  };
  struct Fragment {
    Key key;
    std::span<const Byte> prefix;
    std::span<const Byte> payload;
    std::size_t offset = 0;
    std::size_t previous_header = 0;
    Byte next_header = 0;
    bool more = false;
    std::string_view error;
  };
  struct Range { std::size_t offset; std::size_t size; bool more; };
  struct Entry {
    Key key;
    Event event;
    Clock::time_point created;
    std::optional<SensitiveAllocation<Memory>> storage;
    std::array<Range, 128> ranges;
    std::size_t count = 0;
    std::size_t received = 0;
    std::size_t prefix = 0;
    Byte next_header = 0;
    std::optional<std::size_t> length;
  };

public:
  static constexpr std::size_t maximum_datagrams = 32;
  static constexpr std::size_t maximum_payload = UINT16_MAX;
  static constexpr std::size_t maximum_prefix = 256;
  static constexpr auto lifetime = std::chrono::seconds{60};

  explicit IpFragments(Memory &memory) noexcept : memory_(memory) {}

  template <typename Consume, typename Report>
  void packet(const Event &event, Consume consume, Report report) {
    const auto network = NetworkPacket::decode(event);
    auto fragment = parse(network);
    if (!fragment) { consume(network); return; }
    auto &part = *fragment;
    part.key.session = event.session;
    part.key.interface = event.interface_index;
    part.key.link_type = event.link_type;
    std::ranges::copy(event.interface.substr(0, part.key.name.size()), part.key.name.begin());
    if (!part.error.empty()) { report(event, part.error); return; }
    if (part.key.ipv6 && part.offset == 0 && !part.more) {
      Entry atomic;
      initialize(atomic, event, part.key);
      atomic.storage.emplace(memory_, maximum_prefix + maximum_payload);
      const auto error = append(atomic, part);
      if (!error.empty()) { report(event, error); return; }
      consume(assembled(atomic));
      return;
    }

    const auto now = Clock::now();
    std::optional<Entry> *slot = nullptr;
    for (auto &entry : entries_) {
      if (entry && entry->key == part.key) { slot = &entry; break; }
    }
    if (slot && now - (*slot)->created >= lifetime) {
      if ((*slot)->storage) { failure(**slot, "ip_fragment_timeout", report); }
      slot->reset();
    }
    if (!slot) {
      const auto free = std::ranges::find_if(entries_, [](const auto &entry) { return !entry; });
      slot = free == entries_.end() ? &*std::min_element(entries_.begin(), entries_.end(), [](const auto &first, const auto &second) { return first->created < second->created; }) : &*free;
      if (*slot && (*slot)->storage) { failure(**slot, "ip_fragment_capacity", report); }
      slot->reset();
    }
    if (!*slot) {
      Entry entry;
      initialize(entry, event, part.key);
      entry.storage.emplace(memory_, maximum_prefix + maximum_payload);
      slot->emplace(std::move(entry));
    }
    auto &entry = **slot;
    if (!entry.storage) { return; }
    const auto error = append(entry, part);
    if (!error.empty()) { failure(entry, error, report); return; }
    if (entry.prefix != 0 && entry.length && entry.received == *entry.length) {
      auto completed = std::move(*slot);
      slot->reset();
      consume(assembled(*completed));
    }
  }

  template <typename Report>
  void expire(Report report, bool stop = false, Clock::time_point now = Clock::now()) {
    for (auto &entry : entries_) {
      if (entry && (stop || now - entry->created >= lifetime)) {
        if (entry->storage) { failure(*entry, stop ? "ip_fragment_capture_stopped" : "ip_fragment_timeout", report); }
        entry.reset();
      }
    }
  }

private:
  static std::optional<Fragment> parse(std::span<const Byte> bytes) noexcept {
    if (bytes.empty()) { return {}; }
    Fragment part;
    if ((bytes[0] >> 4) == 4) {
      if (bytes.size() < 20 || (NetworkPacket::word(bytes, 6) & 0x3fff) == 0) { return {}; }
      const auto flags = NetworkPacket::word(bytes, 6);
      part.offset = std::size_t{flags & 0x1fffu} * 8;
      part.more = (flags & 0x2000) != 0;
      part.key.identification = NetworkPacket::word(bytes, 4);
      part.key.protocol = bytes[9];
      std::copy_n(bytes.begin() + 12, 8, part.key.addresses.begin());
      const auto head = std::size_t{bytes[0] & 15u} * 4;
      const auto length = NetworkPacket::word(bytes, 2);
      if (head < 20 || head > bytes.size() || length <= head || length > bytes.size() || (flags & 0xc000) != 0) { part.error = "ip_fragment_invalid_or_truncated"; return part; }
      part.prefix = bytes.first(head);
      part.payload = bytes.subspan(head, length - head);
    } else if ((bytes[0] >> 4) == 6) {
      if (bytes.size() < 40) { return {}; }
      const auto length = std::size_t{NetworkPacket::word(bytes, 4)} + 40;
      auto protocol = bytes[6];
      std::size_t offset = 40;
      part.previous_header = 6;
      for (unsigned depth = 0; protocol != 44; ++depth) {
        if (depth == 8 || offset > bytes.size() || bytes.size() - offset < 2 || (protocol != 0 && protocol != 43 && protocol != 60 && protocol != 51)) { return {}; }
        const auto head = protocol == 51 ? (std::size_t{bytes[offset + 1]} + 2) * 4 : (std::size_t{bytes[offset + 1]} + 1) * 8;
        part.previous_header = offset;
        protocol = bytes[offset];
        offset += head;
      }
      part.key.ipv6 = true;
      if (offset > bytes.size() || bytes.size() - offset < 8 || length > bytes.size() || length <= offset + 8 || offset > maximum_prefix) { part.error = "ip_fragment_invalid_or_truncated"; return part; }
      std::copy_n(bytes.begin() + 8, 32, part.key.addresses.begin());
      part.key.identification = (std::uint32_t{NetworkPacket::word(bytes, offset + 4)} << 16) | NetworkPacket::word(bytes, offset + 6);
      const auto flags = NetworkPacket::word(bytes, offset + 2);
      part.offset = flags & 0xfff8u;
      part.more = (flags & 1) != 0;
      part.next_header = bytes[offset];
      part.prefix = bytes.first(offset);
      part.payload = bytes.subspan(offset + 8, length - offset - 8);
    } else { return {}; }
    if ((part.more && part.payload.size() % 8 != 0) || part.offset + part.payload.size() > maximum_payload) { part.error = "ip_fragment_size_limit"; }
    return part;
  }

  static void initialize(Entry &entry, Event event, const Key &key) noexcept {
    entry.key = key;
    event.bytes = {};
    event.interface = {};
    entry.event = event;
    entry.created = Clock::now();
  }

  static std::string_view append(Entry &entry, const Fragment &part) {
    const auto end = part.offset + part.payload.size();
    if (entry.length && (end > *entry.length || (!part.more && end != *entry.length))) { return "ip_fragment_conflicting_length"; }
    for (const auto &range : std::span{entry.ranges}.first(entry.count)) {
      if (range.offset == part.offset && range.size == part.payload.size() && range.more == part.more && std::ranges::equal(entry.storage->bytes().subspan(maximum_prefix + part.offset, range.size), part.payload)) {
        if (part.offset == 0 && (entry.prefix != part.prefix.size() || (part.key.ipv6 && entry.next_header != part.next_header))) { return "ip_fragment_overlap"; }
        return {};
      }
      if (part.offset < range.offset + range.size && range.offset < end) { return "ip_fragment_overlap"; }
      if (!part.more && range.offset + range.size > end) { return "ip_fragment_conflicting_length"; }
    }
    if (entry.count == entry.ranges.size()) { return "ip_fragment_piece_limit"; }
    if (part.offset == 0) {
      entry.prefix = part.prefix.size();
      entry.next_header = part.next_header;
      std::ranges::copy(part.prefix, entry.storage->bytes().begin() + maximum_prefix - entry.prefix);
      if (part.key.ipv6) { entry.storage->bytes()[maximum_prefix - entry.prefix + part.previous_header] = part.next_header; }
    }
    std::ranges::copy(part.payload, entry.storage->bytes().begin() + maximum_prefix + part.offset);
    entry.ranges[entry.count++] = {part.offset, part.payload.size(), part.more};
    entry.received += part.payload.size();
    if (!part.more) { entry.length = end; }
    if (entry.prefix != 0 && entry.length && entry.prefix - (entry.key.ipv6 ? 40 : 0) + *entry.length > UINT16_MAX) { return "ip_fragment_size_limit"; }
    return {};
  }

  static std::span<const Byte> assembled(Entry &entry) {
    auto bytes = entry.storage->bytes().subspan(maximum_prefix - entry.prefix, entry.prefix + *entry.length);
    const auto length = bytes.size() - (entry.key.ipv6 ? 40 : 0);
    const auto offset = entry.key.ipv6 ? 4u : 2u;
    bytes[offset] = static_cast<Byte>(length >> 8);
    bytes[offset + 1] = static_cast<Byte>(length);
    if (!entry.key.ipv6) {
      bytes[6] = bytes[7] = bytes[10] = bytes[11] = 0;
      std::uint32_t sum = 0;
      for (std::size_t index = 0; index < entry.prefix; index += 2) { sum += NetworkPacket::word(bytes, index); }
      while (sum >> 16) { sum = (sum & UINT16_MAX) + (sum >> 16); }
      const auto checksum = static_cast<std::uint16_t>(~sum);
      bytes[10] = static_cast<Byte>(checksum >> 8);
      bytes[11] = static_cast<Byte>(checksum);
    }
    return bytes;
  }

  template <typename Report>
  static void failure(Entry &entry, std::string_view reason, Report report) {
    entry.storage.reset();
    auto event = entry.event;
    event.interface = {entry.key.name.data(), strnlen(entry.key.name.data(), entry.key.name.size())};
    report(event, reason);
  }

  Memory &memory_;
  std::array<std::optional<Entry>, maximum_datagrams> entries_;
};

}
