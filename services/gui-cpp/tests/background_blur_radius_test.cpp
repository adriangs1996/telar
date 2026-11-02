#include "assertions.hpp"
#include "platform/macos/blur_radius.hpp"
#include "platform/window.hpp"
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <utility>

namespace {
using telar::gui::platform::BlurRadius;
using telar::gui::platform::NativeBlurTarget;
using telar::gui::platform::WindowAppearance;
using telar::gui::test::require;

constexpr NativeBlurTarget initial{.number = 73, .style = 9};
constexpr NativeBlurTarget replacement{.number = 74, .style = 9};
constexpr NativeBlurTarget restyled{.number = 74, .style = 10};
constexpr std::uint8_t initial_radius = 20;
constexpr std::uint8_t changed_radius = 37;
constexpr float translucent_opacity = 0.98F;
constexpr float half_opacity = 0.5F;

enum class Calls : std::uint8_t {
  initial = 1,
  reloaded = 2,
  opaque = 3,
  replaced = 4,
  restyled = 5,
  rejected = 6,
};
enum class Reply : std::uint8_t {
  success,
  rejected,
};

struct Observation {
  std::size_t calls = 0;
  std::pair<std::size_t, int> last;
  Reply reply = Reply::success;
};

Observation &observation() {
  static Observation value;
  return value;
}

void *connection() {
  return &observation();
}

std::int32_t setRadius(void *handle, std::size_t native_window, int native_radius) {
  require(handle == &observation(), "numeric blur must use its injected native connection");
  auto &observed = *static_cast<Observation *>(handle);
  ++observed.calls;
  observed.last = std::pair{native_window, native_radius};
  return static_cast<std::int32_t>(observed.reply);
}

void verifyCalls(Calls expected) {
  require(observation().calls == static_cast<std::size_t>(expected), "native blur must preserve its exact call count");
}

void verifyRadius() {
  auto &observed = observation();
  BlurRadius blur{{.connection = connection, .set_radius = setRadius}};
  WindowAppearance appearance{.background_opacity = translucent_opacity, .background_blur = initial_radius};
  require(blur.apply(initial, appearance), "supported numeric blur must disable the material fallback");
  verifyCalls(Calls::initial);
  require(observed.last == std::pair{static_cast<std::size_t>(initial.number), static_cast<int>(initial_radius)}, "blur must preserve the configured window and numeric radius");
  require(blur.apply(initial, appearance), "unchanged supported blur must stay numeric");
  verifyCalls(Calls::initial);
  appearance.background_blur = changed_radius;
  require(blur.apply(initial, appearance) && std::cmp_equal(observed.last.second, changed_radius), "reload must apply a different positive radius");
  verifyCalls(Calls::reloaded);
  appearance.background_opacity = 1;
  require(blur.apply(initial, appearance) && observed.last.second == 0, "opaque windows must reset numeric blur to zero");
  verifyCalls(Calls::opaque);
  appearance.background_opacity = half_opacity;
  appearance.background_blur = 0;
  require(blur.apply(initial, appearance), "disabled blur must share the cached zero radius");
  verifyCalls(Calls::opaque);
  appearance.background_blur = initial_radius;
  require(blur.apply(replacement, appearance), "native window replacement must reapply blur");
  verifyCalls(Calls::replaced);
  require(blur.apply(restyled, appearance), "native style transitions must reapply blur");
  verifyCalls(Calls::restyled);
  observed.reply = Reply::rejected;
  require(!blur.apply(initial, appearance), "native rejection must retain the material fallback");
  verifyCalls(Calls::rejected);
  require(!blur.apply(initial, appearance), "unchanged rejected state must retain reference retry policy");
  verifyCalls(Calls::rejected);
  const NativeBlurTarget unassigned;
  require(!blur.apply(unassigned, appearance), "unassigned native windows must not be sent to the server");
  verifyCalls(Calls::rejected);
  BlurRadius unavailable{{}};
  require(!unavailable.apply(initial, appearance), "unavailable symbols must retain material fallback");
}
}

int main() {
  try {
    verifyRadius();
    std::cout << "native blur radius, disable, replacement and fallback passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
