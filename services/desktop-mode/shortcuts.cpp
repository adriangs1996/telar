#include "shortcuts.hpp"
#include <array>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <utility>

namespace {
  void
  configure(void *router, const std::string &prefix, std::span<const Shortcuts::Binding> bindings) {
    if (bindings.size() > 256 || prefix.find('\0') != std::string::npos) {
      throw std::runtime_error("Invalid shortcut prefix or too many bindings (maximum 256)");
    }

    std::array<TelarKeyBinding, 256> native{};

    for (std::size_t index = 0; index < bindings.size(); ++index) {
      const auto &binding = bindings[index];

      if (binding.keys.empty() || binding.keys.size() > 5) {
        throw std::runtime_error("A shortcut requires 1 to 5 keys including its prefix");
      }

      auto &entry = native[index];
      entry.action = binding.id;
      entry.count = binding.keys.size();

      for (std::size_t key = 0; key < binding.keys.size(); ++key) {
        if (binding.keys[key].find('\0') != std::string::npos) {
          throw std::runtime_error("A shortcut key cannot contain NUL");
        }

        entry.keys[key] = binding.keys[key].c_str();
      }
    }

    if (const auto *error =
            telar_keymap_configure(router, prefix.c_str(), native.data(), bindings.size())) {
      throw std::runtime_error(std::string("Invalid shortcuts: ") + error);
    }
  }
} // namespace

Shortcuts::Shortcuts()
    : router_(telar_keymap_create()) {
  if (!router_) {
    throw std::bad_alloc{};
  }
}

Shortcuts::~Shortcuts() {
  telar_keymap_destroy(router_);
}

std::uint64_t Shortcuts::nextId() {
  return next_id_++;
}

void Shortcuts::validate(const std::string &prefix, std::span<const Binding> bindings) const {
  std::unique_ptr<void, decltype(&telar_keymap_destroy)> temporary(telar_keymap_create(),
                                                                   telar_keymap_destroy);

  if (!temporary) {
    throw std::bad_alloc{};
  }

  configure(temporary.get(), prefix, bindings);
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

  configure(router_, prefix.empty() ? "ctrl+b" : prefix, bindings);
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

bool Shortcuts::route(const TelarShortcutKey &key) {
  std::uint64_t action = 0;
  const bool consumed = telar_keymap_route(router_, &key, &action);

  if (action && sink_ && !sink_({action, epoch_})) {
    std::fputs("Desktop shortcut dropped: application event queue is full\n", stderr);
  }

  return consumed;
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
  telar_keymap_cancel(router_);
}

bool Shortcuts::pending() const {
  return telar_keymap_pending(router_);
}

bool Shortcuts::empty() const {
  for (const auto &[_, group] : groups_) {
    if (!group.bindings.empty()) {
      return false;
    }
  }

  return true;
}
