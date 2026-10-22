#include "../desktop.hpp"
#include "session.hpp"
#include <algorithm>

struct NativeDesktop::Impl {
  Sink sink;
  std::uint64_t subscription = 0;
  std::uint64_t next_space = std::uint64_t{1} << 32;
  DesktopState state;
  DesktopState delivered;

  void publish() {
    if (sink && state != delivered && sink(state)) {
      delivered = state;
    }
  }

  void reconcile(const linux_desktop::Snapshot &snapshot) {
    state.available = !snapshot.outputs.empty();
    state.accessibility = true;
    state.focused_space = snapshot.focused_space;
    if (state.pending_space == state.focused_space) {
      state.pending_space = 0;
    }
    state.displays.clear();
    for (const auto &output : snapshot.outputs) {
      state.displays.push_back({output.id,
                                output.name.toStdString(),
                                double(output.geometry.x()),
                                double(output.geometry.y()),
                                double(output.geometry.width()),
                                double(output.geometry.height())});
      if (std::ranges::none_of(state.spaces, [&](const auto &space) {
            return space.display == output.id;
          })) {
        state.spaces.push_back(
            {.id = output.space, .uuid = output.name.toStdString() + ":1", .display = output.id});
      }
      std::uint32_t index = 0;
      for (auto &space : state.spaces) {
        if (space.display != output.id) {
          continue;
        }
        space.index = ++index;
        space.visible = space.id == output.space;
        space.focused = space.id == state.focused_space;
      }
    }
    std::erase_if(state.spaces, [&](const auto &space) {
      return std::ranges::none_of(snapshot.outputs, [&](const auto &output) {
        return space.display == output.id;
      });
    });
    publish();
  }
};

NativeDesktop::NativeDesktop()
    : impl_(std::make_unique<Impl>()) {}

NativeDesktop::~NativeDesktop() {
  stop();
}

void NativeDesktop::start(Sink publish) {
  impl_->sink = std::move(publish);
  impl_->subscription = linux_desktop::Session::get().subscribe([this](const auto &snapshot) {
    impl_->reconcile(snapshot);
  });
}

void NativeDesktop::stop() {
  if (!impl_->subscription) {
    return;
  }
  linux_desktop::Session::get().unsubscribe(impl_->subscription);
  impl_->subscription = 0;
  impl_->sink = {};
}

void NativeDesktop::activate(std::uint64_t space) {
  const auto found = std::ranges::find(impl_->state.spaces, space, &DesktopSpace::id);
  if (found == impl_->state.spaces.end()) {
    return;
  }
  impl_->state.pending_space = space;
  impl_->publish();
  linux_desktop::Session::get().post([output = found->display, space](telar_server *server) {
    telar_server_space(server, output, space);
  });
}

void NativeDesktop::changeSpace(SpaceOperation operation) {
  auto &state = impl_->state;
  SpaceCompletion completion{operation, false, {}};
  const auto display = std::ranges::find(state.displays, operation.display, &DesktopDisplay::id);
  if (display == state.displays.end()) {
    completion.error = "The requested display no longer exists";
  } else if (operation.kind == SpaceOperation::Kind::create) {
    const auto id = ++impl_->next_space;
    state.spaces.push_back(
        {.id = id, .uuid = display->uuid + ":" + std::to_string(id), .display = operation.display});
    completion.operation.space = id;
    completion.succeeded = true;
  } else {
    const auto target = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);
    const auto replacement = std::ranges::find_if(state.spaces, [&](const auto &space) {
      return space.display == operation.display && space.id != operation.space;
    });
    if (target == state.spaces.end() || target->display != operation.display ||
        replacement == state.spaces.end()) {
      completion.error = "The last Space of a display cannot be removed";
    } else {
      const auto next = replacement->id;
      linux_desktop::Session::get().post(
          [operation, next, visible = target->visible](telar_server *server) {
            telar_server_move_space(server, operation.space, next);
            if (visible) {
              telar_server_space(server, operation.display, next);
            }
          });
      state.spaces.erase(target);
      completion.succeeded = true;
    }
  }
  state.completed_operation = completion;
  impl_->reconcile(linux_desktop::Session::get().snapshot());
}
