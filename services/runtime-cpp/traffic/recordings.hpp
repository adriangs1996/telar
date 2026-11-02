#pragma once

#include "recording_protocol.hpp"
#include "recording_owner.hpp"
#include "filter.hpp"
#include "flow.hpp"
#include "pcapng.hpp"
#include "event_frame.hpp"
#include "../memory/sensitive_allocation.hpp"
#include "../plugins/protocol.hpp"
#include "../proxy/host_policy.hpp"
#include <atomic>
#include <chrono>
#include <mutex>

namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory, typename Clock = std::chrono::steady_clock>
class Recordings {
  using Request = recording::Request;
  struct Entry {
    std::uint64_t cursor;
    typename Clock::time_point created;
    std::shared_ptr<EventFrame<Memory>> frame;
  };

  struct Session {
    explicit Session(Memory &memory, const Request &request, std::uint64_t id, recording::Owner owner)
        : id(id), owner(std::move(owner)), budget(request.max_bytes), age(request.max_age_ms), selection(request.selection), filter(request.filter), host(memory), entries(AllocatorRef<std::optional<Entry>, Memory>{memory}) {
      if (!request.host.empty() && !host.append(request.host)) { throw EncodingError{"Invalid recording host scope"}; }
      host.finish();
      entries.resize(request.max_events);
      bytes = entries.capacity() * sizeof(std::optional<Entry>);
      if (bytes >= budget) { throw EncodingError{"Recording budget cannot hold its event index"}; }
    }

    Entry &at(std::size_t index) { return *entries[(head + index) % entries.size()]; }
    void evict() noexcept {
      bytes -= at(0).frame->bytes.bytes().size();
      entries[head].reset();
      head = (head + 1) % entries.size();
      --count;
      ++evicted;
    }
    void expire(typename Clock::time_point now) noexcept {
      while (count != 0 && now - at(0).created >= age) { evict(); }
    }

    std::uint64_t id;
    recording::Owner owner;
    std::size_t budget;
    std::chrono::milliseconds age;
    Selection selection;
    Filter filter;
    ProxyHostPolicy<Memory> host;
    Vector<std::optional<Entry>, Memory> entries;
    std::size_t bytes = 0;
    std::size_t head = 0;
    std::size_t count = 0;
    std::uint64_t next = 1;
    std::uint64_t evicted = 0;
    std::uint64_t dropped = 0;
    bool active = true;
  };

public:
  explicit Recordings(Memory &memory) noexcept : memory_(memory) { ::arc4random_buf(&next_id_, sizeof(next_id_)); }

  bool selects(Selection selection) const noexcept { return (interest_.load(std::memory_order_acquire) & static_cast<Byte>(selection)) != 0; }

  std::shared_ptr<EventFrame<Memory>> record(const Event &event, std::shared_ptr<EventFrame<Memory>> shared = {}) noexcept {
    if (!selected(Selection::all, event.kind) || interest_.load(std::memory_order_acquire) == 0) { return shared; }
    const std::unique_lock lock{mutex_, std::try_to_lock};
    if (!lock.owns_lock()) { contention_drops_.fetch_add(1, std::memory_order_relaxed); return shared; }
    const auto now = Clock::now();
    for (auto &slot : sessions_) {
      if (!slot || !slot->active || !slot->owner.authorized() || !selected(slot->selection, event.kind)) { continue; }
      auto &session = *slot;
      session.expire(now);
      try {
        if (!session.filter.matches(event) || !matches(session.host, event)) { continue; }
        const auto size = Protocol::encodedSize(event);
        const auto index_bytes = session.entries.capacity() * sizeof(std::optional<Entry>);
        if (size > session.budget - index_bytes || session.next == UINT64_MAX) { ++session.dropped; continue; }
        while (session.count != 0 && (session.count == session.entries.size() || size > session.budget - session.bytes)) { session.evict(); }
        if (!shared) {
          shared = std::allocate_shared<EventFrame<Memory>>(AllocatorRef<EventFrame<Memory>, Memory>{memory_}, memory_, size);
          Protocol::encode(shared->bytes.bytes(), event);
        }
        session.entries[(session.head + session.count) % session.entries.size()].emplace(Entry{session.next++, now, shared});
        ++session.count;
        session.bytes += size;
      } catch (...) { ++session.dropped; }
    }
    return shared;
  }

  void expire() noexcept {
    const std::unique_lock lock{mutex_, std::try_to_lock};
    if (!lock.owns_lock()) { return; }
    for (auto &session : sessions_) { if (session) { session->expire(Clock::now()); } }
  }

  void revoke(const recording::Owner &owner) noexcept {
    const std::lock_guard lock{mutex_};
    for (auto &session : sessions_) { if (session && owner.matches(session->owner)) { session->active = false; } }
    refreshInterest();
  }

  std::span<const Byte> handle(const Request &request, std::span<Byte> output, recording::Owner owner = {}) {
    if (output.size() < recording::Protocol::page_header_bytes) { throw EncodingError{"Recording output is too small"}; }
    std::array<Byte, 8192> validation;
    plugins::FrameWriter validated{validation};
    recording::Protocol::write(validated, request);
    ProxyHostPolicy scope{memory_};
    if (!request.host.empty() && !scope.append(request.host)) { throw EncodingError{"Invalid recording query host"}; }
    scope.finish();
    const std::lock_guard lock{mutex_};
    if (!owner.authorized()) { throw EncodingError{"Recording package permission has been revoked"}; }
    if (request.operation == recording::Operation::list) {
      output = output.first(std::min(output.size(), recording::Limits::page_bytes));
      plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};
      recording::Page page{.format = recording::Format::list};
      for (auto &slot : sessions_) {
        if (!slot || !owner.canRead(slot->owner)) { continue; }
        slot->expire(Clock::now());
        std::array<Byte, recording::Protocol::page_header_bytes> bytes;
        plugins::FrameWriter child{bytes};
        recording::Protocol::header(child, describe(*slot));
        rows.bytes(child.finish());
        ++page.count;
      }
      plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};
      recording::Protocol::header(header, page);
      return output.first(header.finish().size() + rows.finish().size());
    }
    Session *session = nullptr;
    if (request.operation == recording::Operation::start) {
      std::uint64_t reserved = request.max_bytes;
      for (const auto &existing : sessions_) { if (existing) { reserved += existing->budget; } }
      if (reserved > recording::Limits::total_bytes) { throw EncodingError{"Recording runtime budget exhausted"}; }
      for (auto &slot : sessions_) {
        if (slot) { continue; }
        if (++next_id_ == 0) { ++next_id_; }
        slot.emplace(memory_, request, next_id_, owner);
        session = &*slot;
        break;
      }
      if (!session) { throw EncodingError{"Recording session limit reached"}; }
      refreshInterest();
    } else {
      for (auto &slot : sessions_) { if (slot && slot->id == request.id && owner.canRead(slot->owner)) { session = &*slot; break; } }
      if (!session) { throw EncodingError{"Unknown or expired recording identity"}; }
    }
    session->expire(Clock::now());
    if (request.operation == recording::Operation::stop) { session->active = false; refreshInterest(); }
    auto page = describe(*session);
    output = output.first(std::min(output.size(), recording::Limits::page_bytes));
    if (output.size() < recording::Protocol::page_header_bytes) { throw EncodingError{"Recording output is too small"}; }
    plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};
    if (request.operation == recording::Operation::query || request.operation == recording::Operation::pcapng) {
      if (request.cursor > session->next) { throw EncodingError{"Recording cursor is beyond the current end"}; }
      page.gap = request.cursor != 0 && request.cursor < page.oldest;
      page.next = request.cursor == 0 ? page.oldest : std::max(request.cursor, page.oldest);
      const bool pcapng = request.operation == recording::Operation::pcapng;
      page.format = pcapng ? recording::Format::pcapng : recording::Format::events;
      if (pcapng) { Pcapng::section(rows); }
      for (std::size_t index = 0; index < session->count; ++index) {
        auto &entry = session->at(index);
        if (entry.cursor < page.next) { continue; }
        const auto event = Protocol::decode(entry.frame->bytes.bytes());
        if (!selected(request.selection, event.kind) || !matches(scope, event) || (pcapng && event.kind != Kind::packet)) { page.next = entry.cursor + 1; continue; }
        const auto size = pcapng ? Pcapng::packetBytes(event) : sizeof(std::uint64_t) + sizeof(std::uint32_t) + entry.frame->bytes.bytes().size();
        if (size > output.size() - recording::Protocol::page_header_bytes - rows.finish().size() || page.count == request.limit) { break; }
        if (pcapng) { Pcapng::packet(rows, event, page.count); }
        else { rows.integer(entry.cursor); rows.bytes(entry.frame->bytes.bytes()); }
        ++page.count;
        page.next = entry.cursor + 1;
      }
    }
    if (request.operation == recording::Operation::erase) {
      page.active = false;
      page.bytes = 0;
      for (auto &slot : sessions_) { if (slot && &*slot == session) { slot.reset(); break; } }
      refreshInterest();
    }
    plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};
    recording::Protocol::header(header, page);
    return output.first(header.finish().size() + rows.finish().size());
  }

private:
  recording::Page describe(Session &session) const noexcept {
    return {
        .id = session.id, .active = session.active, .oldest = session.count ? session.at(0).cursor : session.next,
        .next = session.next, .end = session.next, .evicted = session.evicted, .dropped = session.dropped,
        .contention_drops = contention_drops_.load(std::memory_order_relaxed), .bytes = session.bytes,
    };
  }

  static bool selected(Selection selection, Kind kind) noexcept {
    const auto mask = static_cast<Byte>(selection);
    const auto bit = kind == Kind::packet ? Selection::packets : kind == Kind::exchange ? Selection::exchanges : kind == Kind::datagram ? Selection::datagrams : Selection::flows;
    const bool public_event = kind == Kind::packet || kind == Kind::exchange || kind == Kind::datagram || (kind >= Kind::flow_open && kind <= Kind::flow_gap);
    return public_event && (mask & static_cast<Byte>(bit)) != 0;
  }

  static bool matches(const ProxyHostPolicy<Memory> &scope, const Event &event) {
    if (scope.patterns().empty()) { return true; }
    if (event.kind == Kind::exchange) { return scope.contains(plugins::Protocol::decodeExchange(event.bytes).host); }
    if (event.kind >= Kind::flow_open && event.kind <= Kind::flow_gap) { return scope.contains(FlowCodec::decode(event.bytes).host); }
    return false;
  }

  void refreshInterest() noexcept {
    Byte mask = 0;
    for (const auto &session : sessions_) { if (session && session->active) { mask |= static_cast<Byte>(session->selection); } }
    interest_.store(mask, std::memory_order_release);
  }

  Memory &memory_;
  std::array<std::optional<Session>, recording::Limits::sessions> sessions_;
  std::uint64_t next_id_;
  std::mutex mutex_;
  std::atomic<Byte> interest_{0};
  std::atomic<std::uint64_t> contention_drops_{0};
};

}
