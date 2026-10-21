#pragma once

#include "keybindings-engine/router.hpp"
#include <functional>
#include <map>
#include <span>
#include <string>
#include <vector>

// Main-thread service. Native capture queues IDs; App invokes callbacks when draining events.
class Shortcuts final {
public:
  struct Request {
    std::uint64_t id;
    std::uint64_t epoch;
  };

  struct Status {
    bool available = false;
    std::string error;
  };

  struct Binding {
    std::uint64_t id;
    std::vector<std::string> keys;
    std::function<void()> invoke;
  };

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
  void setSink(std::function<bool(Request)> sink);
  bool route(const keybindings::KeyEvent &key);
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
  std::uint64_t next_id_ = 1;
  std::uint64_t epoch_ = 0;
  void compile(const std::map<const void *, Group> &groups);
};
