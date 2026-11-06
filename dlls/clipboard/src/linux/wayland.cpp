#include "backend.hpp"
#include "wlr-data-control-client-protocol.h"
#include <cstring>
#include <fcntl.h>
#include <list>
#include <memory>
#include <optional>
#include <wayland-client.h>

namespace telar::clipboard::linux_backend {
  namespace {
    struct offer {
      zwlr_data_control_offer_v1 *handle;
      std::array<bool, formats.size()> available{};

      explicit offer(zwlr_data_control_offer_v1 *value)
          : handle(value) {}

      ~offer() {
        if (handle != nullptr) {
          zwlr_data_control_offer_v1_destroy(handle);
        }
      }
    };

    struct connection {
      wl_display *display = nullptr;
      wl_registry *registry = nullptr;
      wl_seat *seat = nullptr;
      zwlr_data_control_manager_v1 *manager = nullptr;
      zwlr_data_control_device_v1 *device = nullptr;
      std::list<offer> offers;
      offer *selected = nullptr;
      std::uint64_t revision = 0;
      std::uint32_t seat_id = 0;
      std::uint32_t manager_id = 0;
      std::optional<read_error> failure;

      ~connection() {
        offers.clear();
        if (device != nullptr) {
          zwlr_data_control_device_v1_destroy(device);
        }

        if (manager != nullptr) {
          zwlr_data_control_manager_v1_destroy(manager);
        }

        if (seat != nullptr) {
          wl_seat_destroy(seat);
        }

        if (registry != nullptr) {
          wl_registry_destroy(registry);
        }

        if (display != nullptr) {
          wl_display_disconnect(display);
        }
      }
    };

    void offeredType(void *context, zwlr_data_control_offer_v1 *, const char *type) {
      auto &value = *static_cast<offer *>(context);
      for (std::size_t index = 0; index < formats.size(); ++index) {
        value.available[index] = value.available[index] || std::strcmp(type, formats[index].target) == 0;
      }
    }

    const zwlr_data_control_offer_v1_listener offer_listener{.offer = offeredType};

    void offered(void *context, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *handle) {
      auto &state = *static_cast<connection *>(context);
      try {
        auto &value = state.offers.emplace_back(handle);
        zwlr_data_control_offer_v1_add_listener(handle, &offer_listener, &value);
      } catch (const std::bad_alloc &) {
        zwlr_data_control_offer_v1_destroy(handle);
        state.failure = read_error::allocation_failed;
      }
    }

    void selection(void *context, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *handle) {
      auto &state = *static_cast<connection *>(context);
      if (state.selected != nullptr && state.selected->handle != handle) {
        zwlr_data_control_offer_v1_destroy(state.selected->handle);
        state.selected->handle = nullptr;
      }

      state.selected = nullptr;
      ++state.revision;
      for (auto &value : state.offers) {
        if (handle != nullptr && value.handle == handle) {
          state.selected = &value;
          break;
        }
      }
    }

    void finished(void *context, zwlr_data_control_device_v1 *) {
      static_cast<connection *>(context)->failure = read_error::read_failed;
    }

    void primarySelection(void *, zwlr_data_control_device_v1 *, zwlr_data_control_offer_v1 *) {}

    const zwlr_data_control_device_v1_listener device_listener{
        .data_offer = offered,
        .selection = selection,
        .finished = finished,
        .primary_selection = primarySelection,
    };

    void seatCapabilities(void *, wl_seat *, std::uint32_t) {}

    void seatName(void *, wl_seat *, const char *) {}

    const wl_seat_listener seat_listener{.capabilities = seatCapabilities, .name = seatName};

    void global(void *context, wl_registry *registry, std::uint32_t id, const char *interface, std::uint32_t) {
      auto &state = *static_cast<connection *>(context);
      if (state.manager == nullptr && std::strcmp(interface, zwlr_data_control_manager_v1_interface.name) == 0) {
        state.manager = static_cast<zwlr_data_control_manager_v1 *>(wl_registry_bind(registry, id, &zwlr_data_control_manager_v1_interface, 1));
        state.manager_id = id;
      } else if (state.seat == nullptr && std::strcmp(interface, wl_seat_interface.name) == 0) {
        state.seat = static_cast<wl_seat *>(wl_registry_bind(registry, id, &wl_seat_interface, 1));
        state.seat_id = id;
        if (state.seat != nullptr) {
          wl_seat_add_listener(state.seat, &seat_listener, nullptr);
        }
      }
    }

    void removed(void *context, wl_registry *, std::uint32_t id) {
      auto &state = *static_cast<connection *>(context);
      if (id == state.seat_id || id == state.manager_id) {
        state.failure = read_error::read_failed;
      }
    }

    const wl_registry_listener registry_listener{.global = global, .global_remove = removed};

    std::expected<void, read_error> flush(connection &state, deadline expires) {
      while (wl_display_flush(state.display) < 0) {
        if (errno != EAGAIN) {
          return std::unexpected(read_error::read_failed);
        }

        if (auto status = wait(wl_display_get_fd(state.display), POLLOUT, expires); !status) {
          return status;
        }
      }

      return {};
    }

    // A bounded round trip avoids hanging on an unresponsive compositor.
    std::expected<void, read_error> synchronize(connection &state, deadline expires) {
      bool done = false;
      const wl_callback_listener listener{
          .done = [](void *context, wl_callback *, std::uint32_t) { *static_cast<bool *>(context) = true; },
      };
      std::unique_ptr<wl_callback, decltype(&wl_callback_destroy)> callback(wl_display_sync(state.display), wl_callback_destroy);
      if (!callback) {
        return std::unexpected(read_error::allocation_failed);
      }

      wl_callback_add_listener(callback.get(), &listener, &done);
      while (!done) {
        if (wl_display_dispatch_pending(state.display) < 0 || state.failure) {
          return std::unexpected(state.failure.value_or(read_error::read_failed));
        }

        if (done) {
          break;
        }

        if (wl_display_prepare_read(state.display) != 0) {
          continue;
        }

        auto status = flush(state, expires);
        if (status) {
          status = wait(wl_display_get_fd(state.display), POLLIN, expires);
        }

        if (!status) {
          wl_display_cancel_read(state.display);
          return status;
        }

        if (wl_display_read_events(state.display) < 0) {
          return std::unexpected(read_error::read_failed);
        }
      }

      if (state.failure) {
        return std::unexpected(*state.failure);
      }

      return {};
    }

    std::expected<content, read_error> receive(connection &state, const format &type, deadline expires, std::size_t maximum_bytes) {
      int pipe[2];
      if (pipe2(pipe, O_CLOEXEC) != 0) {
        return std::unexpected(read_error::read_failed);
      }

      const descriptor reading(pipe[0]);
      {
        const descriptor writing(pipe[1]);
        if (fcntl(reading.get(), F_SETFL, O_NONBLOCK) < 0) {
          return std::unexpected(read_error::read_failed);
        }

        zwlr_data_control_offer_v1_receive(state.selected->handle, type.target, writing.get());
      }

      if (auto status = flush(state, expires); !status) {
        return std::unexpected(status.error());
      }

      content result{.mime_type = type.mime_type, .bytes = {}};
      std::array<byte, 64 * 1024> buffer;
      for (;;) {
        if (clock::now() >= expires) {
          return std::unexpected(read_error::timed_out);
        }

        const auto count = ::read(reading.get(), buffer.data(), buffer.size());
        if (count > 0) {
          if (static_cast<std::size_t>(count) > maximum_bytes - result.bytes.size()) {
            return std::unexpected(read_error::content_too_large);
          }
          result.bytes.insert(result.bytes.end(), buffer.begin(), buffer.begin() + count);
        } else if (count == 0) {
          break;
        } else if (errno == EAGAIN) {
          if (auto status = wait(reading.get(), POLLIN, expires); !status) {
            return std::unexpected(status.error());
          }
        } else if (errno != EINTR) {
          return std::unexpected(read_error::read_failed);
        }
      }

      if (result.bytes.empty() && type.mime_type.starts_with("image/")) {
        return std::unexpected(read_error::read_failed);
      }

      return result;
    }
  }

  std::expected<content, read_error> readWayland(deadline expires, std::size_t maximum_bytes) {
    connection state;
    state.display = wl_display_connect(nullptr);
    if (state.display == nullptr) {
      return std::unexpected(read_error::session_unavailable);
    }

    state.registry = wl_display_get_registry(state.display);
    if (state.registry == nullptr) {
      return std::unexpected(read_error::allocation_failed);
    }

    wl_registry_add_listener(state.registry, &registry_listener, &state);
    if (auto status = synchronize(state, expires); !status) {
      return std::unexpected(status.error());
    }

    if (state.manager == nullptr || state.seat == nullptr) {
      return std::unexpected(read_error::unsupported_protocol);
    }

    state.device = zwlr_data_control_manager_v1_get_data_device(state.manager, state.seat);
    if (state.device == nullptr) {
      return std::unexpected(read_error::allocation_failed);
    }

    zwlr_data_control_device_v1_add_listener(state.device, &device_listener, &state);
    if (auto status = synchronize(state, expires); !status) {
      return std::unexpected(status.error());
    }

    if (state.selected == nullptr) {
      return std::unexpected(read_error::no_supported_content);
    }

    for (std::size_t index = 0; index < formats.size(); ++index) {
      if (!state.selected->available[index]) {
        continue;
      }

      const auto revision = state.revision;
      auto result = receive(state, formats[index], expires, maximum_bytes);
      if (!result) {
        return result;
      }

      if (auto status = synchronize(state, expires); !status) {
        return std::unexpected(status.error());
      }

      if (state.revision != revision) {
        return std::unexpected(read_error::changed);
      }

      return result;
    }

    return std::unexpected(read_error::no_supported_content);
  }
}
