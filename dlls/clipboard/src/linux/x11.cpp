#include "backend.hpp"
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <utility>
#include <xcb/xcb.h>
#include <xcb/xcbext.h>

namespace telar::clipboard::linux_backend {
  namespace {
    struct release {
      void operator()(void *value) const {
        std::free(value);
      }
    };

    template <typename T>
    using owned = std::unique_ptr<T, release>;

    struct connection {
      xcb_connection_t *handle = nullptr;
      xcb_window_t window = XCB_WINDOW_NONE;
      xcb_atom_t clipboard = XCB_ATOM_NONE;
      xcb_atom_t property = XCB_ATOM_NONE;
      xcb_atom_t incremental = XCB_ATOM_NONE;

      ~connection() {
        if (handle != nullptr) {
          xcb_disconnect(handle);
        }
      }
    };

    template <typename T>
    std::expected<owned<T>, read_error> reply(connection &state, unsigned int sequence, deadline expires) {
      for (;;) {
        if (clock::now() >= expires) {
          xcb_discard_reply(state.handle, sequence);
          return std::unexpected(read_error::timed_out);
        }

        void *value = nullptr;
        xcb_generic_error_t *error = nullptr;
        if (xcb_poll_for_reply(state.handle, sequence, &value, &error) != 0) {
          const owned<xcb_generic_error_t> failure(error);
          owned<T> result(static_cast<T *>(value));
          if (failure || !result) {
            return std::unexpected(read_error::read_failed);
          }

          return result;
        }

        if (xcb_connection_has_error(state.handle) != 0) {
          return std::unexpected(read_error::read_failed);
        }

        xcb_flush(state.handle);
        if (auto status = wait(xcb_get_file_descriptor(state.handle), POLLIN, expires); !status) {
          xcb_discard_reply(state.handle, sequence);
          return std::unexpected(status.error());
        }
      }
    }

    std::expected<xcb_atom_t, read_error> intern(connection &state, const char *name, deadline expires) {
      const auto cookie = xcb_intern_atom(state.handle, 0, static_cast<std::uint16_t>(std::strlen(name)), name);
      auto value = reply<xcb_intern_atom_reply_t>(state, cookie.sequence, expires);
      if (!value) {
        return std::unexpected(value.error());
      }

      return (*value)->atom;
    }

    std::expected<owned<xcb_generic_event_t>, read_error> nextEvent(connection &state, deadline expires) {
      for (;;) {
        if (clock::now() >= expires) {
          return std::unexpected(read_error::timed_out);
        }

        if (owned<xcb_generic_event_t> event{xcb_poll_for_event(state.handle)}; event) {
          if (event->response_type == 0) {
            return std::unexpected(read_error::read_failed);
          }

          return event;
        }

        if (xcb_connection_has_error(state.handle) != 0) {
          return std::unexpected(read_error::read_failed);
        }

        xcb_flush(state.handle);
        if (auto status = wait(xcb_get_file_descriptor(state.handle), POLLIN, expires); !status) {
          return std::unexpected(status.error());
        }
      }
    }

    struct property_info {
      xcb_atom_t type = XCB_ATOM_NONE;
      std::uint8_t format = 0;
      std::size_t length = 0;
    };

    // Check the remaining budget before appending each chunk, including INCR transfers.
    std::expected<property_info, read_error> readProperty(connection &state, std::vector<byte> &bytes, deadline expires, std::size_t maximum_bytes) {
      constexpr std::uint32_t chunk_bytes = 64 * 1024;
      constexpr std::uint32_t property_unit_bytes = 4;
      std::uint32_t offset = 0;
      property_info info;
      for (;;) {
        const auto cookie = xcb_get_property(state.handle, 1, state.window, state.property, XCB_GET_PROPERTY_TYPE_ANY, offset, chunk_bytes / property_unit_bytes);
        auto value = reply<xcb_get_property_reply_t>(state, cookie.sequence, expires);
        if (!value) {
          return std::unexpected(value.error());
        }

        const auto &part = **value;
        const int count = xcb_get_property_value_length(value->get());
        if (count < 0 || static_cast<unsigned int>(count) > chunk_bytes || part.type == XCB_ATOM_NONE) {
          return std::unexpected(read_error::read_failed);
        }

        if (offset == 0) {
          info.type = part.type;
          info.format = part.format;
        } else if (part.type != info.type || part.format != info.format) {
          return std::unexpected(read_error::read_failed);
        }

        if (count != 0) {
          if (static_cast<std::size_t>(count) > maximum_bytes - bytes.size()) {
            return std::unexpected(read_error::content_too_large);
          }
          const auto *data = static_cast<const byte *>(xcb_get_property_value(value->get()));
          bytes.insert(bytes.end(), data, data + count);
          info.length += static_cast<std::size_t>(count);
        }

        if (part.bytes_after == 0) {
          return info;
        }

        const auto units = static_cast<std::uint32_t>(count) / property_unit_bytes;
        if (count == 0 || static_cast<unsigned int>(count) % property_unit_bytes != 0 || offset > std::numeric_limits<std::uint32_t>::max() - units) {
          return std::unexpected(read_error::read_failed);
        }

        offset += units;
      }
    }

    std::expected<void, read_error> convert(connection &state, xcb_atom_t target, deadline expires) {
      xcb_convert_selection(state.handle, state.window, state.clipboard, target, state.property, XCB_CURRENT_TIME);
      xcb_flush(state.handle);
      for (;;) {
        auto event = nextEvent(state, expires);
        if (!event) {
          return std::unexpected(event.error());
        }

        if (((*event)->response_type & 0x7f) != XCB_SELECTION_NOTIFY) {
          continue;
        }

        const auto *notification = reinterpret_cast<const xcb_selection_notify_event_t *>(event->get());
        if (notification->requestor == state.window && notification->selection == state.clipboard && notification->target == target) {
          if (notification->property != state.property) {
            return std::unexpected(read_error::no_supported_content);
          }

          return {};
        }
      }
    }

    std::expected<void, read_error> waitIncrement(connection &state, deadline expires) {
      for (;;) {
        auto event = nextEvent(state, expires);
        if (!event) {
          return std::unexpected(event.error());
        }

        if (((*event)->response_type & 0x7f) != XCB_PROPERTY_NOTIFY) {
          continue;
        }

        const auto *notification = reinterpret_cast<const xcb_property_notify_event_t *>(event->get());
        if (notification->window == state.window && notification->atom == state.property && notification->state == XCB_PROPERTY_NEW_VALUE) {
          return {};
        }
      }
    }

    std::expected<content, read_error> receive(connection &state, xcb_atom_t target, std::string_view mime_type, deadline expires, std::size_t maximum_bytes) {
      if (auto status = convert(state, target, expires); !status) {
        return std::unexpected(status.error());
      }

      content result{.mime_type = mime_type, .bytes = {}};
      auto info = readProperty(state, result.bytes, expires, maximum_bytes);
      if (!info) {
        return std::unexpected(info.error());
      }

      if (info->type == state.incremental) {
        // xclip can omit the size hint; an empty 32-bit INCR property is safe to accept.
        if (info->format != 32 || (info->length != 0 && info->length != sizeof(std::uint32_t))) {
          return std::unexpected(read_error::read_failed);
        }

        // Never allocate using the owner's untrusted INCR size hint.
        result.bytes.clear();
        do {
          if (auto status = waitIncrement(state, expires); !status) {
            return std::unexpected(status.error());
          }

          info = readProperty(state, result.bytes, expires, maximum_bytes);
          if (!info) {
            return std::unexpected(info.error());
          }

          if (info->type != target || info->format != 8) {
            return std::unexpected(read_error::read_failed);
          }
        } while (info->length != 0);
      } else if (info->type != target || info->format != 8) {
        return std::unexpected(read_error::read_failed);
      }

      if (result.bytes.empty() && mime_type.starts_with("image/")) {
        return std::unexpected(read_error::read_failed);
      }

      return result;
    }

    std::expected<xcb_window_t, read_error> owner(connection &state, deadline expires) {
      auto value = reply<xcb_get_selection_owner_reply_t>(state, xcb_get_selection_owner(state.handle, state.clipboard).sequence, expires);
      if (!value) {
        return std::unexpected(value.error());
      }

      return (*value)->owner;
    }
  }

  std::expected<content, read_error> readX11(deadline expires, std::size_t maximum_bytes) {
    connection state;
    int screen_index = 0;
    state.handle = xcb_connect(nullptr, &screen_index);
    if (state.handle == nullptr || xcb_connection_has_error(state.handle) != 0) {
      return std::unexpected(read_error::session_unavailable);
    }

    auto screen = xcb_setup_roots_iterator(xcb_get_setup(state.handle));
    for (int index = 0; index < screen_index && screen.rem != 0; ++index) {
      xcb_screen_next(&screen);
    }

    if (screen.rem == 0) {
      return std::unexpected(read_error::session_unavailable);
    }

    state.window = xcb_generate_id(state.handle);
    const std::uint32_t events = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_create_window(state.handle, XCB_COPY_FROM_PARENT, state.window, screen.data->root, 0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT, XCB_CW_EVENT_MASK, &events);

    xcb_atom_t targets = XCB_ATOM_NONE;
    const std::pair<const char *, xcb_atom_t *> names[] = {
        {"CLIPBOARD", &state.clipboard},
        {"_TELAR_CLIPBOARD", &state.property},
        {"INCR", &state.incremental},
        {"TARGETS", &targets},
    };
    for (const auto &[name, destination] : names) {
      const auto atom = intern(state, name, expires);
      if (!atom) {
        return std::unexpected(atom.error());
      }

      *destination = *atom;
    }

    const auto original_owner = owner(state, expires);
    if (!original_owner) {
      return std::unexpected(original_owner.error());
    }

    if (*original_owner == XCB_WINDOW_NONE) {
      return std::unexpected(read_error::no_supported_content);
    }

    if (auto status = convert(state, targets, expires); !status) {
      return std::unexpected(status.error());
    }

    std::vector<byte> available;
    const auto info = readProperty(state, available, expires, 64 * 1024);
    if (!info || info->type != XCB_ATOM_ATOM || info->format != 32 || available.size() % sizeof(xcb_atom_t) != 0) {
      return std::unexpected(info ? read_error::read_failed : info.error());
    }

    for (const auto &format : formats) {
      const auto target = intern(state, format.target, expires);
      if (!target) {
        return std::unexpected(target.error());
      }

      for (std::size_t offset = 0; offset < available.size(); offset += sizeof(xcb_atom_t)) {
        xcb_atom_t advertised;
        std::memcpy(&advertised, available.data() + offset, sizeof(advertised));
        if (advertised != *target) {
          continue;
        }

        auto result = receive(state, *target, format.mime_type, expires, maximum_bytes);
        if (!result) {
          return result;
        }

        const auto current_owner = owner(state, expires);
        if (!current_owner) {
          return std::unexpected(current_owner.error());
        }

        if (*current_owner != *original_owner) {
          return std::unexpected(read_error::changed);
        }

        return result;
      }
    }

    return std::unexpected(read_error::no_supported_content);
  }
}
