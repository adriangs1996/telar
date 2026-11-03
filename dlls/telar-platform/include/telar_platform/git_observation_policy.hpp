#pragma once

#include <array>
#include <optional>
#include <string_view>

namespace telar::runtime {

struct GitRepositoryFacts {
  static constexpr std::size_t maximum_drivers = 8;
  std::array<std::string_view, maximum_drivers> drivers;
  std::size_t driver_count = 0;
  bool may_fetch = false;

  static std::optional<GitRepositoryFacts> parse(std::string_view listing) noexcept {
    GitRepositoryFacts facts;
    while (!listing.empty()) {
      const auto scope_end = listing.find('\0');
      if (scope_end == 0) {
        break;
      }
      if (scope_end == std::string_view::npos) {
        return std::nullopt;
      }

      const auto scope = listing.substr(0, scope_end);
      listing.remove_prefix(scope_end + 1);
      const auto entry_end = listing.find('\0');
      if (entry_end == std::string_view::npos) {
        return std::nullopt;
      }
      const auto entry = listing.substr(0, entry_end);
      listing.remove_prefix(entry_end + 1);
      if (scope != "local" && scope != "worktree") {
        continue;
      }

      const auto key = entry.substr(0, entry.find('\n'));
      if (key == "extensions.partialclone" || (key.starts_with("remote.") && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter") || key.ends_with(".uploadpack")))) {
        facts.may_fetch = true;
        continue;
      }

      constexpr std::string_view prefix = "filter.";
      const auto variable = key.rfind('.');
      if (!key.starts_with(prefix) || variable < prefix.size()) {
        continue;
      }
      const auto driver = key.substr(prefix.size(), variable - prefix.size());
      if (driver.find_first_of("=\n") != std::string_view::npos) {
        return std::nullopt;
      }

      bool known = false;
      for (std::size_t index = 0; index < facts.driver_count; ++index) {
        known |= facts.drivers[index] == driver;
      }
      if (!known) {
        if (facts.driver_count == maximum_drivers) {
          return std::nullopt;
        }
        facts.drivers[facts.driver_count++] = driver;
      }
    }

    return facts;
  }
};

inline constexpr auto git_observation_options = std::to_array<std::string_view>({
    "git",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "hook.applypatch-msg.enabled=false",
    "-c",
    "hook.pre-applypatch.enabled=false",
    "-c",
    "hook.post-applypatch.enabled=false",
    "-c",
    "hook.pre-commit.enabled=false",
    "-c",
    "hook.pre-merge-commit.enabled=false",
    "-c",
    "hook.prepare-commit-msg.enabled=false",
    "-c",
    "hook.commit-msg.enabled=false",
    "-c",
    "hook.post-commit.enabled=false",
    "-c",
    "hook.pre-rebase.enabled=false",
    "-c",
    "hook.post-checkout.enabled=false",
    "-c",
    "hook.post-merge.enabled=false",
    "-c",
    "hook.pre-push.enabled=false",
    "-c",
    "hook.pre-receive.enabled=false",
    "-c",
    "hook.update.enabled=false",
    "-c",
    "hook.proc-receive.enabled=false",
    "-c",
    "hook.post-receive.enabled=false",
    "-c",
    "hook.post-update.enabled=false",
    "-c",
    "hook.reference-transaction.enabled=false",
    "-c",
    "hook.push-to-checkout.enabled=false",
    "-c",
    "hook.pre-auto-gc.enabled=false",
    "-c",
    "hook.post-rewrite.enabled=false",
    "-c",
    "hook.sendemail-validate.enabled=false",
    "-c",
    "hook.fsmonitor-watchman.enabled=false",
    "-c",
    "hook.post-index-change.enabled=false",
});

}
