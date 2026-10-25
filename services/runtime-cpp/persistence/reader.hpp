#pragma once

#include <algorithm>

#include "records.hpp"

namespace telar::runtime::checkpoint {

class Reader {
public:
  explicit Reader(std::span<const Byte> bytes)
      : input_(bytes) {
    if (bytes.size() > maximum_bytes || text(magic.size()) != magic) {
      throw EncodingError{"Invalid checkpoint header"};
    }

    version_ = u16::decode(input_);
    if (version_ == 0 || version_ > current_version) {
      throw EncodingError{"Unsupported checkpoint version"};
    }

    counters = {u64::decode(input_), u64::decode(input_), u64::decode(input_), u64::decode(input_)};
    if (counters.workspace == 0 || counters.tab == 0 || counters.pane == 0 || counters.generation == 0) {
      throw EncodingError{"Invalid checkpoint counters"};
    }
  }

  template <typename Consumer>
  void read(Consumer &&consume) {
    std::size_t pane_count = 0;
    for (;;) {
      switch (static_cast<Kind>(u8::decode(input_))) {
      case Kind::end:
        if (!input_.empty()) {
          throw EncodingError{"Trailing checkpoint bytes"};
        }

        return;
      case Kind::workspace: {
        const WorkspaceRecord record{u64::decode(input_), text16(), text16(), u64::decode(input_), text16()};
        validatePath(record.path);
        if (record.name.size() > 256 || record.first_label.size() > 128 || (version_ < 3 && record.first_label.empty())) {
          throw EncodingError{"Invalid checkpoint workspace label"};
        }

        consume(record);
        break;
      }
      case Kind::tab: {
        const TabRecord record{u64::decode(input_), u64::decode(input_), text16()};
        if (record.label.size() > 128 || (version_ < 3 && record.label.empty())) {
          throw EncodingError{"Invalid checkpoint tab label"};
        }

        consume(record);
        break;
      }
      case Kind::pane: {
        const auto record = pane();
        if (!record) {
          break;
        }
        if (++pane_count > 256) {
          throw EncodingError{"Checkpoint has too many panes"};
        }

        consume(*record);
        break;
      }
      case Kind::layout: {
        const LayoutRecord record{u64::decode(input_), u64::decode(input_), bytes32()};
        if (record.payload.empty() || record.payload.size() > 16 * 1024) {
          throw EncodingError{"Invalid checkpoint layout size"};
        }

        consume(record);
        break;
      }
      case Kind::worktree: {
        const auto record = worktree();
        try {
          validatePath(record.registration.path);
          if (record.id == 0) {
            throw EncodingError{"Invalid checkpoint worktree identity"};
          }
          Codec::encodedSize(record.registration);
        } catch (const EncodingError &) {
          ++skipped_worktrees;
          break;
        }

        consume(record);
        break;
      }
      default:
        throw EncodingError{"Unknown checkpoint record"};
      }
    }
  }

  Counters counters;
  std::size_t skipped_worktrees = 0;

private:
  bool boolean() {
    const auto value = u8::decode(input_);
    if (value > 1) {
      throw EncodingError{"Invalid checkpoint boolean"};
    }

    return value != 0;
  }

  std::string_view text(std::size_t length) {
    if (length > input_.size()) {
      throw EncodingError{"Truncated checkpoint text"};
    }

    const std::string_view result{reinterpret_cast<const char *>(input_.data()), length};
    input_ = input_.subspan(length);
    return result;
  }

  std::string_view text16() {
    return text(u16::decode(input_));
  }

  std::span<const Byte> bytes32() {
    const auto value = text(u32::decode(input_));
    return {reinterpret_cast<const Byte *>(value.data()), value.size()};
  }

  std::optional<PaneRecord> pane() {
    PaneRecord record{u64::decode(input_), u64::decode(input_), u64::decode(input_), text16(), u16::decode(input_), u16::decode(input_), u16::decode(input_), {}};
    record.arguments = version_ >= 9 ? text(u32::decode(input_)) : text16();
    validatePath(record.cwd);
    if (record.argument_count > 64 || record.arguments.size() > 128 * 1024 || std::ranges::count(record.arguments, '\0') != record.argument_count) {
      throw EncodingError{"Invalid checkpoint launch arguments"};
    }

    record.provider = static_cast<AgentProvider>(u8::decode(input_));
    record.session = text16();
    if (!record.session.empty()) {
      validateAgentSession(record.session, false);
    }
    if (version_ >= 2) {
      record.title = text16();
      record.title_source = static_cast<AgentTitleSource>(u8::decode(input_));
    }
    validateTitle(record.title, record.title_source);

    record.in_pane = version_ >= 8 && boolean();
    if (version_ == 4 && boolean()) {
      return std::nullopt;
    }
    if (record.argument_count == 0) {
      throw EncodingError{"Checkpoint launch has no arguments"};
    }

    return record;
  }

  WorktreeRecord worktree() {
    WorktreeRecord record{};
    record.id = u64::decode(input_);
    auto &registration = record.registration;
    registration.request_id = 1;
    registration.source = u64::decode(input_);
    record.workspace = u64::decode(input_);
    const auto created_by = u64::decode(input_);
    if (created_by != 0) {
      registration.created_by = created_by;
    }
    registration.origin = static_cast<WorktreeOrigin>(u8::decode(input_));
    registration.path = text16();
    registration.branch = text16();
    registration.base = text16();
    registration.title = text16();
    registration.brief = text16();
    if (version_ >= 7) {
      registration.dispatched_from = text16();
    }
    if (version_ >= 10 && boolean()) {
      CoordinatorReference coordinator;
      const auto session = text(coordinator.session_id.size());
      std::copy(session.begin(), session.end(), coordinator.session_id.begin());
      coordinator.pane_id = u64::decode(input_);
      coordinator.pane_generation = u64::decode(input_);
      registration.coordinator = coordinator;
    }

    return record;
  }

  std::span<const Byte> input_;
  std::uint16_t version_;
};

}
