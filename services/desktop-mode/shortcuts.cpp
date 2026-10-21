#include "shortcuts.hpp"
#include <array>
#include <cstdio>
#include <stdexcept>
#include <utility>

namespace {
  auto engineBindings(std::span<const Shortcuts::Binding> bindings) {
    if (bindings.size() > keybindings::maxBindings) {
      throw std::runtime_error("Too many shortcuts (maximum 256)");
    }

    std::array<keybindings::Binding, keybindings::maxBindings> result{};

    for (std::size_t index = 0; index < bindings.size(); ++index) {
      const auto &binding = bindings[index];
      result[index] = {binding.id, binding.keys};
    }

    return result;
  }
} // namespace

std::uint64_t Shortcuts::nextId() {
  return next_id_++;
}

void Shortcuts::validate(const std::string &prefix, std::span<const Binding> bindings) const {
  const auto entries = engineBindings(bindings);
  const keybindings::Keymap validated(prefix, std::span(entries).first(bindings.size()));
}

void Shortcuts::compile(const std::map<const void *, Group> &groups) {
  std::string prefix;
  std::vector<Binding> bindings;

  for (const auto &[_, group] : groups) {
    if (group.bindings.empty()) {
      continue;
    }

    if (!prefix.empty() && prefix != group.prefix) {
      throw std::runtime_error("Desktop surfaces must use the same shortcut prefix");
    }

    prefix = group.prefix;
    bindings.insert(bindings.end(), group.bindings.begin(), group.bindings.end());
  }

  const auto entries = engineBindings(bindings);
  router_.configure(prefix.empty() ? "ctrl+b" : prefix, std::span(entries).first(bindings.size()));
  ++epoch_;
}

void Shortcuts::install(const void *owner,
                        const std::string &prefix,
                        std::span<const Binding> bindings,
                        const void *replacing) {
  auto candidate = groups_;
  candidate.erase(replacing);
  candidate[owner] = {prefix, {bindings.begin(), bindings.end()}};
  compile(candidate);
  groups_.swap(candidate);
}

void Shortcuts::remove(const void *owner) {
  if (!groups_.contains(owner)) {
    return;
  }

  auto candidate = groups_;
  candidate.erase(owner);
  compile(candidate);
  groups_.swap(candidate);
}

void Shortcuts::setSink(std::function<bool(Request)> sink) {
  sink_ = std::move(sink);
  cancel();
}

bool Shortcuts::route(const keybindings::KeyEvent &key) {
  const auto decision = router_.route(key);

  if (decision.action && sink_ && !sink_({decision.action, epoch_})) {
    std::fputs("Desktop shortcut dropped: application event queue is full\n", stderr);
  }

  return decision.consumed;
}

void Shortcuts::dispatch(Request request) {
  if (request.epoch != epoch_) {
    return;
  }

  for (const auto &[_, group] : groups_) {
    for (const auto &binding : group.bindings) {
      if (binding.id == request.id) {
        auto callback = binding.invoke;
        callback();
        return;
      }
    }
  }
}

void Shortcuts::cancel() {
  ++epoch_;
  router_.cancel();
}

bool Shortcuts::pending() const {
  return router_.pending();
}

bool Shortcuts::empty() const {
  for (const auto &[_, group] : groups_) {
    if (!group.bindings.empty()) {
      return false;
    }
  }

  return true;
}
