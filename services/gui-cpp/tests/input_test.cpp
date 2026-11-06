#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif



#include <cstddef>
#include <cstdint>
#include <array>
#include <optional>
#include <string_view>
#include <utility>
#include <algorithm>
#include <span>
#include <stdexcept>
#include <tuple>
#include <cmath>
#include <concepts>
#include <limits>
#include <cstdio>
#include <exception>
#include <initializer_list>
#include <iostream>




import telar.gui.history.browser;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;
import telar.gui.input.configuration;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_filter_geometry;

import telar.gui.config.gui_query;

namespace {

using namespace telar::gui;

enum class TestAction : std::uint8_t {
  first,
  second,
};

using Router = KeyRouter<TestAction>;
using Outcome = Router::Outcome;

constexpr KeyChord prefix{.key = KeyChord::Key::character, .character = 'b', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

constexpr KeyChord character(char text) noexcept {
  return {.key = KeyChord::Key::character, .character = static_cast<std::uint32_t>(text)};
}

KeyBinding<TestAction> binding(std::initializer_list<KeyChord> keys, TestAction action) {
  KeyBinding<TestAction> result{.length = keys.size(), .action = action};
  std::ranges::copy(keys, result.keys.begin());

  return result;
}

void prefixesAndMisses() {
  const std::array bindings{binding({prefix, character('s')}, TestAction::first), binding({character('g'), character('g')}, TestAction::second)};
  Router router{BindingMap<TestAction>{bindings}, prefix};
  require(router.route({.chord = prefix, .physical = 1}, 0).outcome == Outcome::pending, "the prefix must hold its first press");
  require(router.prefixPending() && !router.deadline(), "the application prefix must not inherit the global sequence timeout");
  require(router.expire(std::numeric_limits<std::uint64_t>::max()).outcome == Outcome::pending, "elapsed time alone must not dismiss a prefix");
  const auto action = router.route({.chord = character('s'), .physical = 2}, 1);
  require(action.outcome == Outcome::action && action.action == TestAction::first && !router.prefixPending(), "a matching suffix must emit its configured action");
  require(router.route({.chord = character('S'), .phase = KeyPhase::release, .physical = 2}, 2).outcome == Outcome::discard, "binding releases must retain ownership when their chord changes");
  static_cast<void>(router.route({.chord = prefix, .physical = 1}, 3));
  require(router.route({.chord = character('x'), .physical = 3}, 4).outcome == Outcome::discard, "an unmatched prefixed suffix must not leak into the terminal");

  static_cast<void>(router.route({.chord = prefix}, 0));
  require(router.route({.chord = {.key = KeyChord::Key::escape}}, 1).outcome == Outcome::discard && !router.prefixPending(), "plain Escape must cancel a pending prefix");
  static_cast<void>(router.route({.chord = character('g'), .physical = 1}, 0));
  const auto replay = router.route({.chord = character('x'), .physical = 2}, 1);
  require(replay.outcome == Outcome::replay && replay.held_count == 1 && replay.held[0].chord == character('g') && replay.has_current && replay.event.chord == character('x'), "global sequence misses must replay held keys before the current key");
  require(router.route({.chord = character('g'), .phase = KeyPhase::release, .physical = 1}, 2).outcome == Outcome::forward, "replayed physical input must transfer release ownership to its recipient");
}

void timeoutsAndCapture() {
  const std::array bindings{binding({prefix, character('s')}, TestAction::first), binding({character('g'), character('g')}, TestAction::second)};
  Router router{BindingMap<TestAction>{bindings}, prefix};
  constexpr std::uint64_t timeout_ns = 100;
  constexpr std::uint64_t started_ns = 10;
  router.setTimeout(timeout_ns);
  static_cast<void>(router.route({.chord = character('g'), .physical = 1}, started_ns));
  require(router.deadline() == started_ns + timeout_ns && router.expire(started_ns + timeout_ns - 1).outcome == Outcome::pending, "global chords must wait until their exact deadline");
  const auto expired = router.expire(started_ns + timeout_ns);
  require(expired.outcome == Outcome::replay && expired.held_count == 1 && !expired.has_current && !router.deadline(), "expiration must replay only the captured sequence once");
  static_cast<void>(router.route({.chord = character('g')}, 0));
  const auto capture = router.route({.chord = character('x')}, 1, {.captures_keys = true, .repeat = std::nullopt});
  require(capture.outcome == Outcome::replay && capture.has_current, "an exclusive input owner must receive an interrupted global sequence and its current key");
  static_cast<void>(router.route({.chord = prefix}, 0));
  require(router.route({.chord = character('x')}, 1, {.captures_keys = true, .repeat = std::nullopt}).outcome == Outcome::forward, "exclusive capture must discard an unfinished application prefix");
  static_cast<void>(router.route({.chord = character('g')}, 0));
  router.cancelSequence();
  require(router.interrupt().outcome == Outcome::discard, "semantic focus changes must discard partial sequences");
}

void physicalRepeatsAndReload() {
  const std::array bindings{binding({character('s')}, TestAction::first)};
  Router router{BindingMap<TestAction>{bindings}};
  constexpr std::uint64_t repeat_interval_ns = 100;
  constexpr BindingRepeat policy{.interval_ns = repeat_interval_ns, .owner = 1};
  const auto action = router.route({.chord = character('s'), .physical = 1}, 0);
  router.actionCompleted(action, policy);
  require(router.route({.chord = character('s'), .phase = KeyPhase::repeat, .physical = 1}, repeat_interval_ns - 1, {.repeat = policy}).outcome == Outcome::discard, "early repeats must not accelerate a binding");
  const auto repeat = router.route({.chord = character('s'), .phase = KeyPhase::repeat, .physical = 1}, repeat_interval_ns, {.repeat = policy});
  require(repeat.outcome == Outcome::action && repeat.repeated && repeat.action == TestAction::first, "eligible repeats must emit one action at the configured interval");
  constexpr BindingRepeat changed_owner{.interval_ns = repeat_interval_ns, .owner = 2};
  require(router.route({.chord = character('s'), .phase = KeyPhase::repeat, .physical = 1}, repeat_interval_ns * 2, {.repeat = changed_owner}).outcome == Outcome::discard && !router.repeatAction(), "changing an action's recipient must cancel physical repetition");
  const auto next = router.route({.chord = character('s'), .physical = 2}, 0);
  router.actionCompleted(next, policy);
  Router replacement;
  replacement.inheritLeases(router);
  require(!replacement.repeatAction() && replacement.route({.chord = character('x'), .phase = KeyPhase::repeat, .physical = 2}, 0).outcome == Outcome::discard, "configuration replacement must retain physical ownership without repeating obsolete actions");
  require(replacement.route({.chord = character('x'), .phase = KeyPhase::release, .physical = 2}, 0).outcome == Outcome::discard, "an obsolete binding's release must not be reclassified by the new map");
  static_cast<void>(replacement.route({.chord = character('x'), .physical = 3}, 0));
  require(replacement.route({.chord = character('x'), .phase = KeyPhase::repeat, .physical = 3}, 0).outcome == Outcome::forward, "ordinary input repeats must remain with the application");
}

void capacityAndAmbiguity() {
  Router router;
  for (std::size_t index = 0; index < BindingLimits::physical_keys; ++index) {
    require(router.route({.chord = character('x'), .physical = index + 1}, 0).outcome == Outcome::forward, "bounded physical ownership must admit every available slot");
  }

  constexpr auto overflow_identity = BindingLimits::physical_keys + 1;
  require(router.route({.chord = character('x'), .physical = overflow_identity}, 0).outcome == Outcome::discard && router.overflowCount() == 1, "saturated physical ownership must drop a press without reallocating");
  static_cast<void>(router.route({.chord = character('x'), .phase = KeyPhase::release, .physical = 1}, 0));
  require(router.route({.chord = character('x'), .physical = overflow_identity}, 0).outcome == Outcome::forward, "a released physical key must restore capacity");
  const std::array bindings{binding({character('g')}, TestAction::first), binding({character('g'), character('g')}, TestAction::second)};
  bool rejected = false;
  try {
    const BindingMap<TestAction> ambiguous{bindings};
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected, "a keymap must reject ambiguous configured sequences before adoption");
}

void generatedDefaultsAndOverrides() {
  InputConfiguration configuration;
  require(configuration.compile().size() == default_bindings.size(), "all declarative Zig defaults must compile into the C++ map");
  configuration.configured[0] = {.keys = {prefix, character('c')}, .length = 2, .action = {.kind = BindingActionKind::history_palette}, .prefixed = true};
  configuration.length = 1;
  const auto compiled = configuration.compile();
  KeyRouter<BindingAction> router{compiled, configuration.prefix};
  static_cast<void>(router.route({.chord = prefix}, 0));
  const auto replaced = router.route({.chord = character('c')}, 0);
  require(replaced.outcome == decltype(router)::Outcome::action && replaced.action.kind == BindingActionKind::history_palette, "configured bindings must replace conflicting defaults");

  constexpr KeyChord changed_prefix{.key = KeyChord::Key::character, .character = 'a', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
  configuration.setPrefix(changed_prefix);
  require(configuration.configured[0].keys[0] == changed_prefix, "profile prefix overrides must also rebase inherited prefixed bindings");
  const auto indexed = builtinBindingAction("select-tab-1_0");
  constexpr std::int32_t expected_index = 9;
  require(indexed && indexed->kind == BindingActionKind::select_tab && indexed->parameter == expected_index && !builtinBindingAction("select-tab-0"), "indexed action names must preserve the original one-based configuration syntax");
}

void historyActionsRetainTheirChoice() {
  constexpr float extent = 10;
  constexpr HistoryActionPosition position{.x = 5, .y = 5};
  constexpr HistoryChoice original{.index = 0, .revision = std::numeric_limits<std::uint64_t>::max() - 1};
  HistoryActionSurface surface{.generation = 1, .choice = original};
  surface.targets[0] = {.action = HistoryCardAction::copy, .bounds = {.width = extent, .height = extent}, .enabled = true};
  HistoryActionCapture capture;
  require(capture.begin(surface, position, true), "a visible history action must consume its press");
  ++surface.choice->revision;
  require(!capture.release(surface, position), "replaced results must cancel a held action without an intermediate disabled frame");
  require(capture.begin(surface, position, true), "a new result must accept a fresh press");
  require(capture.release(surface, position) == HistoryCardAction::copy, "a fresh press must act on the new result");

  require(capture.begin(surface, position, true), "selection test must capture the action");
  ++surface.choice->index;
  capture.present(surface);
  --surface.choice->index;
  require(!capture.release(surface, position), "returning to the original selection must not revive a cancelled press");

  surface.targets[0].enabled = false;
  require(capture.begin(surface, position, true), "disabled actions must still consume their press");
  surface.targets[0].enabled = true;
  require(!capture.release(surface, position), "enabling an action must not revive a press that began disabled");
  require(capture.begin(surface, position, false), "secondary buttons must retain ownership");
  require(!capture.release(surface, position), "secondary buttons must not activate history actions");
}

}

int main() {
  try {
    prefixesAndMisses();
    timeoutsAndCapture();
    physicalRepeatsAndReload();
    capacityAndAmbiguity();
    generatedDefaultsAndOverrides();
    historyActionsRetainTheirChoice();
    std::puts("gui-input: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-input: " << error.what() << '\n';

    return 1;
  }
}
