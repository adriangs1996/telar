#pragma once

#include "keybindings-engine/router.hpp"
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <vector>

// Main-thread service. Native capture queues IDs; App invokes callbacks when draining events.
class Shortcuts final {
public:
  // The modifiers a held binding waits on; shift is left out, so it can turn a cycle around.
  enum Modifier : std::uint8_t {
    control = 1 << 0,
    alt = 1 << 1,
    command = 1 << 2,
  };

  struct Request {
    std::uint64_t id;
    std::uint64_t epoch;
    // The binding's modifiers came up after it fired.
    bool release = false;
  };

  struct Status {
    bool available = false;
    std::string error;
  };

  struct Binding {
    std::uint64_t id;
    std::vector<std::string> keys;
    std::function<void()> invoke;
    // Called once the modifiers held when the binding fired are no longer all down, as Cmd+Tab
    // commits when Cmd comes up.
    std::function<void()> release;
  };

  struct Replacement {
    const void *owner;
    const void *previous;
    std::string prefix;
    std::vector<Binding> bindings;
  };

  struct Capture {
    keybindings::Router router;
    std::uint64_t epoch;
  };

  // Copies the callback-free engine to a native input thread when the map changes.
  void setCapture(std::function<void(Capture)> capture);
  void submit(Request request);

  Shortcuts() = default;
  Shortcuts(const Shortcuts &) = delete;
  Shortcuts &operator=(const Shortcuts &) = delete;

  std::uint64_t nextId();
  void validate(const std::string &prefix, std::span<const Binding> bindings) const;
  void install(const void *owner,
               const std::string &prefix,
               std::span<const Binding> bindings,
               const void *replacing = nullptr);
  void remove(const void *owner);
  void replace(std::span<const Replacement> replacements);
  void setSink(std::function<bool(Request)> sink);
  bool route(const keybindings::KeyEvent &key);
  // From native capture, after every keyboard event: the Modifier bits held now.
  void setModifiers(std::uint8_t held);
  void dispatch(Request request);
  void cancel();
  bool pending() const;
  bool empty() const;
  Status status;

private:
  struct Group {
    std::string prefix;
    std::vector<Binding> bindings;
  };

  std::map<const void *, Group> groups_;
  std::function<bool(Request)> sink_;
  keybindings::Router router_;
  std::function<void(Capture)> capture_;
  std::uint64_t next_id_ = 1;
  std::uint64_t epoch_ = 0;

  // A fired binding waiting for its modifiers to come up.
  struct Held {
    std::uint64_t id;
    std::uint8_t modifiers;
  };

  std::set<std::uint64_t> releasing_;
  std::optional<Held> held_binding_;
  std::uint8_t held_ = 0;
  void compile(const std::map<const void *, Group> &groups);
};
