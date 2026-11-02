#pragma once

#include "application/client_view_state.hpp"
#include "core/configuration.hpp"
#include "core/json_writer.hpp"
#include "query.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

struct ClientQueryContext {
  std::optional<std::string_view> source;
  std::optional<std::string_view> profile;
  std::uint64_t generation = 0;
  ClientViewState view;
};

class ClientQuery {
public:
  [[nodiscard]] static std::string_view write(const Configuration &configuration, const ClientQueryContext &context, std::span<char> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("source", [&](JsonWriter &value) {
        writeOptionalBytes(value, context.source);
      });
      object.member("profile", [&](JsonWriter &value) {
        writeOptionalBytes(value, context.profile);
      });
      object.member("generation", context.generation);
      object.member("sidebar_visible", context.view.sidebar_visible);
      object.member("sidebar_width", context.view.sidebar_width);
      object.member("workspace_list_collapsed", context.view.workspace_list_collapsed);
      object.member("pane_gaps", context.view.pane_gaps);
      object.member("window_title", context.view.window_title);
      object.member("sound", [&](JsonWriter &value) {
        writeSound(value, configuration.sound);
      });
      object.member("notification_delivery", configuration.notification_delivery == NotificationDelivery::system ? "system" : "telar");
      object.member("history_show_agent_commands", configuration.history.show_agent_commands);
      object.member("history_enter_runs", configuration.history.enter_runs);
      object.member("history_match_fts", configuration.history.match_fts);
      object.member("sections", writeSections);
    });

    return writer.view();
  }

private:
  static void writeOptionalBytes(JsonWriter &writer, std::optional<std::string_view> text) {
    if (text) {
      writer.bytes(byteView(*text));
    } else {
      writer.value(nullptr);
    }
  }

  static void writeSound(JsonWriter &writer, SoundPolicy policy) {
    writer.object([&](JsonWriter &object) {
      object.member("enabled", policy.enabled);
      object.member("ready", policy.ready);
      object.member("needs_input", policy.needs_input);
    });
  }

  static void writeSections(JsonWriter &writer) {
    writer.array([](JsonWriter &sections) {
      for (const auto &[name, section] : ConfigurationQuery::sections) {
        sections.element(name);
      }
    });
  }
};

}
