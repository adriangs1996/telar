#pragma once

#include "records.hpp"

namespace telar::runtime::checkpoint {

class Writer {
public:
  explicit Writer(std::span<Byte> buffer, Counters counters)
      : buffer_(buffer),
        remaining_(buffer.empty() ? buffer : buffer.first(buffer.size() - 1)) {
    constexpr std::size_t header_bytes = magic.size() + sizeof(current_version) + 4 * sizeof(std::uint64_t);
    if (buffer.size() <= header_bytes) {
      throw EncodingError{"Checkpoint buffer cannot hold its header"};
    }

    raw(magic);
    integer(current_version);
    integer(counters.workspace);
    integer(counters.tab);
    integer(counters.pane);
    integer(counters.generation);
  }

  template <typename Record>
  void append(const Record &record) {
    if (dropped != 0) {
      ++dropped;
      return;
    }

    const auto previous = remaining_;
    try {
      write(record);
    } catch (const CapacityReached &) {
      remaining_ = previous;
      dropped = 1;
    }
  }

  std::span<const Byte> finish() {
    const auto count = buffer_.size() - remaining_.size() - 1;
    buffer_[count] = static_cast<Byte>(Kind::end);
    return buffer_.first(count + 1);
  }

  std::size_t dropped = 0;

private:
  struct CapacityReached {};

  void require(std::size_t count) {
    if (count > remaining_.size()) {
      throw CapacityReached{};
    }
  }

  template <std::unsigned_integral Integer>
  void integer(Integer value) {
    require(sizeof(value));
    LittleEndian<Integer>::encode(value, remaining_);
  }

  void raw(std::string_view value) {
    require(value.size());
    std::copy(value.begin(), value.end(), remaining_.begin());
    remaining_ = remaining_.subspan(value.size());
  }

  void text16(std::string_view value) {
    if (value.size() > UINT16_MAX) {
      throw EncodingError{"Checkpoint text exceeds its length field"};
    }

    integer(static_cast<std::uint16_t>(value.size()));
    raw(value);
  }

  void text32(std::string_view value) {
    if (value.size() > maximum_bytes) {
      throw EncodingError{"Checkpoint data exceeds file limit"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    raw(value);
  }

  void kind(Kind value) {
    integer(static_cast<Byte>(value));
  }

  void write(const WorkspaceRecord &record) {
    validatePath(record.path);
    if (record.name.size() > 256 || record.first_label.size() > 128) {
      throw EncodingError{"Invalid checkpoint workspace label"};
    }
    kind(Kind::workspace);
    integer(record.id);
    text16(record.path);
    text16(record.name);
    integer(record.first_tab);
    text16(record.first_label);
  }

  void write(const TabRecord &record) {
    kind(Kind::tab);
    integer(record.workspace);
    integer(record.id);
    text16(record.label);
  }

  void write(const PaneRecord &record) {
    validatePath(record.cwd);
    validateTitle(record.title, record.title_source);
    if (record.argument_count == 0 || record.argument_count > 64 || record.arguments.size() > 128 * 1024 || record.session.size() > 64) {
      throw EncodingError{"Invalid checkpoint launch record"};
    }
    kind(Kind::pane);
    integer(record.id);
    integer(record.workspace);
    integer(record.tab);
    text16(record.cwd);
    integer(record.columns);
    integer(record.rows);
    integer(record.argument_count);
    text32(record.arguments);
    integer(static_cast<Byte>(record.provider));
    text16(record.session);
    text16(record.title);
    integer(static_cast<Byte>(record.title_source));
    integer(static_cast<Byte>(record.in_pane));
  }

  void write(const WorktreeRecord &record) {
    const auto &registration = record.registration;
    auto checked = registration;
    checked.request_id = 1;
    Codec::encodedSize(checked);
    if (record.id == 0) {
      throw EncodingError{"Invalid checkpoint worktree identity"};
    }
    kind(Kind::worktree);
    integer(record.id);
    integer(registration.source);
    integer(record.workspace);
    integer(registration.created_by.value_or(0));
    integer(static_cast<Byte>(registration.origin));
    text16(registration.path);
    text16(registration.branch);
    text16(registration.base);
    text16(registration.title);
    text16(registration.brief);
    text16(registration.dispatched_from);
    integer(static_cast<Byte>(registration.coordinator.has_value()));
    if (registration.coordinator) {
      const auto &coordinator = *registration.coordinator;
      raw({reinterpret_cast<const char *>(coordinator.session_id.data()), coordinator.session_id.size()});
      integer(coordinator.pane_id);
      integer(coordinator.pane_generation);
    }
  }

  void write(const LayoutRecord &record) {
    if (record.payload.empty() || record.payload.size() > 16 * 1024) {
      throw EncodingError{"Invalid checkpoint layout size"};
    }
    kind(Kind::layout);
    integer(record.identity);
    integer(record.last_used);
    text32({reinterpret_cast<const char *>(record.payload.data()), record.payload.size()});
  }

  std::span<Byte> buffer_;
  std::span<Byte> remaining_;
};

}
