#include "virtual_spaces.hpp"
#include "spaces_bridge.hpp"
#include "../../trace.hpp"
#include <algorithm>
#include <stdexcept>
#include <string>

namespace macos::spaces {
  namespace {
    // Space levels. At 0 a layer's windows interleave with the desktop's; below it they go
    // behind macOS's wallpaper, and above it in front of every desktop window.
    enum class Level : int {
      stage = 0,
    };

    bool contains(const DesktopDisplay &display, CGPoint point) {
      return point.x >= display.x && point.x < display.x + display.width && point.y >= display.y &&
             point.y < display.y + display.height;
    }
  } // namespace

  VirtualSpaces &VirtualSpaces::get() {
    static VirtualSpaces spaces;
    return spaces;
  }

  std::optional<VirtualSpaces::Space> VirtualSpaces::find(std::uint64_t space) const {
    const auto found = std::ranges::find(spaces_, space, &Space::stage);
    return found == spaces_.end() ? std::nullopt : std::optional{*found};
  }

  void VirtualSpaces::prepare() {
    TELAR_TRACE("native.virtual_spaces.prepare");
    const auto stray = strayLayers();
    evacuate(stray);
    for (const auto layer : stray) {
      destroyLayer(layer);
    }
  }

  std::uint64_t VirtualSpaces::create(std::uint32_t display) {
    TELAR_TRACE("native.virtual_spaces.create");
    const Space space{
        .stage = createLayer(static_cast<int>(Level::stage)),
        .shelf = createLayer(static_cast<int>(Level::stage)),
        .display = display,
    };

    bool first = false;
    {
      std::scoped_lock lock(mutex_);
      spaces_.push_back(space);
      first = !shown_.contains(display);
      if (first) {
        shown_[display] = space.stage;
      }
    }

    // A new layer's visibility is not documented: both are set.
    const std::uint64_t stage[] = {space.stage};
    const std::uint64_t layers[] = {space.stage, space.shelf};

    if (first) {
      showLayers(stage, std::span(layers).subspan(1));
    } else {
      showLayers({}, layers);
    }

    return space.stage;
  }

  void VirtualSpaces::remove(std::uint64_t space) {
    TELAR_TRACE("native.virtual_spaces.remove");
    std::optional<Space> removed;
    {
      std::scoped_lock lock(mutex_);
      removed = find(space);
    }

    if (!removed) {
      throw std::runtime_error("The requested Space no longer exists");
    }

    const std::uint64_t layers[] = {removed->stage, removed->shelf};
    evacuate(layers);
    destroyLayer(removed->stage);
    destroyLayer(removed->shelf);

    std::scoped_lock lock(mutex_);
    std::erase_if(spaces_, [&](const auto &entry) {
      return entry.stage == space;
    });

    std::erase_if(shown_, [&](const auto &entry) {
      return entry.second == space;
    });
  }

  void VirtualSpaces::release() {
    TELAR_TRACE("native.virtual_spaces.release");
    std::vector<std::uint64_t> layers;
    {
      std::scoped_lock lock(mutex_);
      for (const auto &space : spaces_) {
        layers.push_back(space.stage);
        layers.push_back(space.shelf);
      }

      spaces_.clear();
      shown_.clear();
    }

    evacuate(layers);
    for (const auto layer : layers) {
      destroyLayer(layer);
    }
  }

  void VirtualSpaces::show(std::uint64_t space) {
    TELAR_TRACE("native.virtual_spaces.show");
    std::uint64_t previous = 0;
    {
      std::scoped_lock lock(mutex_);
      const auto found = find(space);
      if (!found) {
        throw std::runtime_error("The requested Space no longer exists");
      }

      auto &shown = shown_[found->display];
      if (shown == space) {
        return;
      }

      previous = std::exchange(shown, space);
    }

    const std::uint64_t incoming[] = {space};
    const std::uint64_t outgoing[] = {previous};
    showLayers(incoming, previous ? outgoing : std::span<const std::uint64_t>());
  }

  std::uint64_t VirtualSpaces::stage(std::uint64_t space) const {
    std::scoped_lock lock(mutex_);
    const auto found = find(space);
    if (!found) {
      throw std::runtime_error("The requested Space no longer exists");
    }

    return found->stage;
  }

  std::uint64_t VirtualSpaces::shelf(std::uint64_t space) const {
    std::scoped_lock lock(mutex_);
    const auto found = find(space);
    if (!found) {
      throw std::runtime_error("The requested Space no longer exists");
    }

    return found->shelf;
  }

  std::uint32_t VirtualSpaces::display(std::uint64_t space) const {
    std::scoped_lock lock(mutex_);
    const auto found = find(space);
    return found ? found->display : 0;
  }

  std::uint64_t VirtualSpaces::resolve(std::uint64_t space, CGPoint point) const {
    std::scoped_lock lock(mutex_);
    if (fullscreen_.contains(space)) {
      return space;
    }

    for (const auto &entry : spaces_) {
      if (entry.stage == space || entry.shelf == space) {
        return entry.stage;
      }
    }

    const auto display = std::ranges::find_if(displays_, [&](const auto &candidate) {
      return contains(candidate, point);
    });

    if (display == displays_.end()) {
      return space;
    }

    const auto shown = shown_.find(display->id);
    return shown == shown_.end() ? space : shown->second;
  }

  void VirtualSpaces::overlay(DesktopState &state) {
    TELAR_TRACE("native.virtual_spaces.overlay");
    const auto focused = std::ranges::find(state.spaces, state.focused_space, &DesktopSpace::id);
    const auto focused_display = focused == state.spaces.end() ? 0 : focused->display;
    const bool focused_fullscreen = focused != state.spaces.end() && focused->fullscreen;
    std::set<std::uint32_t> covered;
    for (const auto &space : state.spaces) {
      if (space.fullscreen && space.visible) {
        covered.insert(space.display);
      }
    }

    std::erase_if(state.spaces, [](const auto &space) {
      return !space.fullscreen;
    });

    std::scoped_lock lock(mutex_);
    displays_ = state.displays;
    fullscreen_.clear();
    for (const auto &space : state.spaces) {
      fullscreen_.insert(space.id);
    }

    // A Space whose display went away moves to the main display, as the Linux compositor's do,
    // hidden.
    const auto gone = [&](std::uint32_t display) {
      return std::ranges::find(state.displays, display, &DesktopDisplay::id) ==
             state.displays.end();
    };

    std::vector<std::uint64_t> orphans;
    std::erase_if(shown_, [&](const auto &entry) {
      if (gone(entry.first)) {
        orphans.push_back(entry.second);
        return true;
      }

      return false;
    });

    for (auto &space : spaces_) {
      if (!state.displays.empty() && gone(space.display)) {
        space.display = state.displays.front().id;
      }
    }

    showLayers({}, orphans);

    if (!focused_fullscreen) {
      const auto shown = shown_.find(focused_display);
      state.focused_space = shown == shown_.end() ? 0 : shown->second;
    }

    std::map<std::uint32_t, std::uint32_t> indices;
    for (const auto &space : spaces_) {
      const auto display = std::ranges::find(state.displays, space.display, &DesktopDisplay::id);
      if (display == state.displays.end()) {
        continue;
      }

      const auto shown = shown_.find(space.display);
      const bool visible =
          shown != shown_.end() && shown->second == space.stage && !covered.contains(space.display);
      state.spaces.push_back({
          .id = space.stage,
          .uuid = display->uuid + ":" + std::to_string(space.stage),
          .display = space.display,
          .index = ++indices[space.display],
          .visible = visible,
          .focused = visible && space.stage == state.focused_space,
      });
    }

    state.available = !state.displays.empty();
  }
} // namespace macos::spaces
