#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct DesktopDisplay {
  std::uint32_t id = 0;
  std::string uuid;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;

  bool operator==(const DesktopDisplay &) const = default;
};

struct DesktopSpace {
  std::uint64_t id = 0;
  std::string uuid;
  std::uint32_t display = 0;
  std::uint32_t index = 0;
  bool visible = false;
  bool focused = false;
  bool fullscreen = false;
  bool managed = false;
  std::optional<std::uint64_t> workspace;

  bool operator==(const DesktopSpace &) const = default;
};

struct SpaceOperation {
  enum class Kind {
    create,
    remove
  };

  std::uint64_t id = 0;
  Kind kind = Kind::create;
  std::uint32_t display = 0;
  std::uint64_t space = 0;

  bool operator==(const SpaceOperation &) const = default;
};

struct SpaceCompletion {
  SpaceOperation operation;
  bool succeeded = false;
  std::string error;

  bool operator==(const SpaceCompletion &) const = default;
};

struct DesktopState {
  bool available = false;
  bool accessibility = false;
  std::uint64_t focused_space = 0;
  std::uint64_t pending_space = 0;
  std::vector<DesktopDisplay> displays;
  std::vector<DesktopSpace> spaces;
  std::optional<SpaceOperation> pending_operation;
  std::optional<SpaceCompletion> completed_operation;
  std::string error;

  bool operator==(const DesktopState &) const = default;
};

// What a desktop state differs in from the one subscribers saw last, so each can skip the work
// for what did not change. The state itself always comes whole: a subscriber that ignores these
// can still reconcile from it.
struct DesktopChanges {
  // The focused Space, or which Space each display shows.
  bool focus = false;
  // Spaces appearing, disappearing, moving or changing their workspace.
  bool spaces = false;
  bool displays = false;
  // A Space activation or operation starting, progressing or completing.
  bool operation = false;
  // Availability, Accessibility permission or the error.
  bool status = false;

  bool any() const {
    return focus || spaces || displays || operation || status;
  }

  bool operator==(const DesktopChanges &) const = default;
};

struct DesktopCommand {
  enum class Kind {
    activate,
    bind,
    create,
    remove
  };

  Kind kind;
  std::uint64_t space = 0;
  std::optional<std::uint64_t> workspace;
  std::uint64_t request = 0;
  std::uint32_t display = 0;
};
