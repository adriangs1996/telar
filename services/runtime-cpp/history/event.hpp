#pragma once

#include "../command_capture/command.hpp"
#include "launch_failure.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <array>

namespace telar::runtime {

struct HistorySession {
  std::array<Byte, 16> id{};
  std::uint64_t pane = 0;
  TabLocation location{};
  std::int64_t started_at_ms = 0;
  std::string_view workspace_path;
  std::string_view shell;
};

enum class HistoryEventKind {
  session_started,
  command_finished,
  session_finished,
  session_title,
  launch_failed
};

struct HistorySessionTitle {
  std::array<Byte, 16> session{};
  FixedText<96> title{};
  AgentTitleSource source = AgentTitleSource::telar;
  AgentTitleState state = AgentTitleState::failed;
};

struct HistoryEventView {
  HistoryEventKind kind;
  HistorySession session;
  CapturedCommand command{};
  std::int64_t finished_at_ms = 0;
  HistorySessionTitle title{};
  LaunchFailure failure{};
};

template <Allocator Memory>
class HistoryEvent {
public:
  explicit HistoryEvent(Memory &memory, const HistoryEventView &event)
      : event_(event),
        workspace_(event.session.workspace_path, AllocatorRef<char, Memory>{memory}),
        shell_(event.session.shell, AllocatorRef<char, Memory>{memory}),
        command_(event.command.command, AllocatorRef<char, Memory>{memory}),
        directory_(event.command.directory, AllocatorRef<char, Memory>{memory}),
        output_(event.command.output.begin(), event.command.output.end(), AllocatorRef<Byte, Memory>{memory}),
        cause_(event.failure.cause, AllocatorRef<char, Memory>{memory}) {}

  HistoryEventView view() const noexcept {
    auto result = event_;
    result.session.workspace_path = workspace_;
    result.session.shell = shell_;
    result.command.command = command_;
    result.command.directory = directory_;
    result.command.output = output_;
    result.failure.cause = cause_;
    return result;
  }

private:
  HistoryEventView event_;
  String<Memory> workspace_;
  String<Memory> shell_;
  String<Memory> command_;
  String<Memory> directory_;
  Vector<Byte, Memory> output_;
  String<Memory> cause_;
};

template <typename Sink>
concept HistoryEventSink = requires(Sink &sink, const HistoryEventView &event) {
  { sink.recordHistory(event) } noexcept -> std::same_as<bool>;
};

struct DiscardedHistory {
  bool recordHistory(const HistoryEventView &) noexcept {
    return true;
  }
};

inline DiscardedHistory discarded_history;

}
