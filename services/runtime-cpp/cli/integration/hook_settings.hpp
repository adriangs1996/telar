#pragma once

#include "../../text/json_node.hpp"
#include "provider.hpp"

namespace telar::runtime::cli::integration {

template <Allocator Memory>
class HookSettings {
public:
  explicit HookSettings(Memory &memory, Provider provider, std::string_view executable)
      : memory_(memory), provider_(provider), marker_{" hook ", AllocatorRef<char, Memory>{memory}}, command_{AllocatorRef<char, Memory>{memory}}, worktree_command_{AllocatorRef<char, Memory>{memory}} {
    if (executable.contains('\'')) {
      throw std::invalid_argument{"Unsupported integration executable path"};
    }

    marker_ += provider.name;
    worktree_command_ = "exec '";
    worktree_command_ += executable;
    worktree_command_ += '\'';
    worktree_command_ += marker_;
    command_ = "[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; ";
    command_ += worktree_command_;
  }

  bool installed(const JsonNode<Memory> &settings, std::string_view event) const noexcept {
    const auto *hooks = settings.find("hooks");
    const auto *entries = hooks == nullptr ? nullptr : hooks->find(event);
    if (entries == nullptr || entries->kind() != JsonKind::array) {
      return false;
    }

    return std::ranges::any_of(entries->children(), [&](const auto &entry) { return findHook(entry) != nullptr; });
  }

  bool install(JsonNode<Memory> &settings) const {
    bool changed = false;
    if (provider_.flat_hooks && settings.find("version") == nullptr) {
      settings.setLiteral("version", "1");
      changed = true;
    }

    auto &hooks = settings.ensure("hooks", JsonKind::object);
    changed = installEvents(hooks, provider_.events, command_, provider_.timeout) || changed;
    changed = installEvents(hooks, provider_.worktree_events, worktree_command_, worktree_timeout) || changed;
    return changed;
  }

  bool uninstall(JsonNode<Memory> &settings) const {
    auto *hooks = settings.find("hooks");
    if (hooks == nullptr || hooks->kind() != JsonKind::object) {
      return false;
    }

    const bool lifecycle_changed = removeEvents(*hooks, provider_.events);
    const bool worktrees_changed = removeEvents(*hooks, provider_.worktree_events);
    return lifecycle_changed || worktrees_changed;
  }

private:
  bool isOwnCommand(const JsonNode<Memory> &hook) const noexcept {
    const auto *command = hook.find("command");
    return command != nullptr && command->kind() == JsonKind::string && command->text().ends_with(marker_);
  }

  template <typename Node>
  Node *findHook(Node &entry) const noexcept {
    if (provider_.flat_hooks) {
      return isOwnCommand(entry) ? &entry : nullptr;
    }

    auto *hooks = entry.find("hooks");
    if (hooks == nullptr || hooks->kind() != JsonKind::array) {
      return nullptr;
    }
    for (auto &hook : hooks->children()) {
      if (isOwnCommand(hook)) {
        return &hook;
      }
    }

    return nullptr;
  }

  bool installEvents(JsonNode<Memory> &hooks, std::span<const std::string_view> events, std::string_view command, std::string_view timeout) const {
    bool changed = false;
    for (const auto event : events) {
      auto &entries = hooks.ensure(event, JsonKind::array);
      bool present = false;
      for (auto &entry : entries.children()) {
        auto *hook = findHook(entry);
        if (hook == nullptr) {
          continue;
        }

        present = true;
        if (hook->find("command")->text() != command) {
          hook->setString("command", command);
          changed = true;
        }
      }
      if (!present) {
        entries.append(newEntry(command, timeout));
        changed = true;
      }
    }

    return changed;
  }

  JsonNode<Memory> newEntry(std::string_view command, std::string_view timeout) const {
    JsonNode<Memory> hook{memory_};
    if (!provider_.flat_hooks) {
      hook.setString("type", "command");
    }

    hook.setString("command", command);
    hook.setLiteral("timeout", timeout);
    if (provider_.flat_hooks) {
      return hook;
    }

    JsonNode<Memory> entry{memory_};
    entry.ensure("hooks", JsonKind::array).append(std::move(hook));
    return entry;
  }

  bool removeEvents(JsonNode<Memory> &hooks, std::span<const std::string_view> events) const {
    bool changed = false;
    for (const auto event : events) {
      auto *entries = hooks.find(event);
      if (entries == nullptr || entries->kind() != JsonKind::array) {
        continue;
      }

      for (std::size_t index = 0; index < entries->children().size();) {
        auto &entry = entries->children()[index];
        bool empty = false;
        if (provider_.flat_hooks) {
          empty = isOwnCommand(entry);
          changed = empty || changed;
        } else if (auto *commands = entry.find("hooks"); commands != nullptr && commands->kind() == JsonKind::array) {
          for (std::size_t command = 0; command < commands->children().size();) {
            if (isOwnCommand(commands->children()[command])) {
              commands->erase(command);
              changed = true;
            } else {
              ++command;
            }
          }

          empty = commands->children().empty();
        }

        if (empty) {
          entries->erase(index);
        } else {
          ++index;
        }
      }
      if (entries->children().empty()) {
        hooks.remove(event);
      }
    }

    return changed;
  }

  Memory &memory_;
  static constexpr std::string_view worktree_timeout = "360";
  Provider provider_;
  String<Memory> marker_;
  String<Memory> command_;
  String<Memory> worktree_command_;
};

}
