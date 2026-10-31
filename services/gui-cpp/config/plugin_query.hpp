#pragma once

#include "core/json_writer.hpp"
#include "plugin_catalog.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui {

struct PluginPage {
  std::string_view text;
  std::int64_t next = -1;
};

class PluginQuery {
public:
  [[nodiscard]] static PluginPage list(const PluginCatalog &catalog, const ClientCommand &request, std::span<char> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = page(request.value, catalog.size());
    JsonWriter writer{output};
    writePage(writer, catalog.generation(), [&](JsonWriter &array) {
      if (index < catalog.size()) {
        array.element([&](JsonWriter &value) {
          listEntry(value, catalog, index);
        });
      }
    });

    return {.text = writer.view(), .next = index + 1 < catalog.size() ? static_cast<std::int64_t>(index + 1) : -1};
  }

  [[nodiscard]] static PluginPage get(const PluginCatalog &catalog, const ClientCommand &request, std::span<char> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = catalog.find(request.text);
    const auto *package = catalog.package(index);
    const auto count = package == nullptr ? 0 : package->manifest.action_count;
    const auto selected = page(request.value, count);
    JsonWriter writer{output};
    writePage(writer, catalog.generation(), [&](JsonWriter &array) {
      if (selected == 0) {
        array.element([&](JsonWriter &value) {
          metadata(value, catalog, index);
        });
      } else {
        array.element(package->manifest.actions[selected - 1].view());
      }
    });

    return {.text = writer.view(), .next = selected < count ? static_cast<std::int64_t>(selected + 1) : -1};
  }

private:
  template <typename Entries>
  static void writePage(JsonWriter &writer, std::uint64_t generation, Entries &&entries) {
    writer.object([&](JsonWriter &object) {
      object.member("generation", generation);
      object.member("entries", [&](JsonWriter &value) {
        value.array(std::forward<Entries>(entries));
      });
    });
  }

  [[nodiscard]] static std::size_t page(std::int64_t value, std::size_t maximum) {
    if (value < 0 || std::cmp_greater(value, maximum)) {
      throw std::invalid_argument{"InvalidPage"};
    }

    return static_cast<std::size_t>(value);
  }

  static void listEntry(JsonWriter &writer, const PluginCatalog &catalog, std::size_t index) {
    const auto &specification = catalog.specification(index);
    const auto *package = catalog.package(index);
    writer.object([&](JsonWriter &object) {
      object.member("index", index);
      object.member("path", specification.path.view());
      object.member("id", package == nullptr ? std::nullopt : std::optional{package->manifest.id.view()});
      object.member("version", package == nullptr ? std::nullopt : std::optional{package->manifest.version.view()});
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
    });
  }

  static void metadata(JsonWriter &writer, const PluginCatalog &catalog, std::size_t index) {
    const auto &specification = catalog.specification(index);
    const auto *package = catalog.package(index);
    writer.object([&](JsonWriter &object) {
      object.member("path", specification.path.view());
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
      if (package == nullptr) {
        object.member("id", nullptr);

        return;
      }

      const auto &manifest = package->manifest;
      object.member("id", manifest.id.view());
      object.member("version", manifest.version.view());
      object.member("entry", manifest.entry.view());
      object.member("source", manifest.source.view());
      object.member("revision", manifest.revision.view());
      object.member("digest", [&](JsonWriter &value) {
        digest(value, package->digest);
      });
      object.member("capabilities", [&](JsonWriter &value) {
        writeCapabilities(value, manifest.capabilities);
      });
    });
  }

  static void writeCapabilities(JsonWriter &writer, runtime::plugins::Capabilities capabilities) {
    using runtime::plugins::Capability;
    writer.array([&](JsonWriter &array) {
      for (unsigned bit = 0; bit <= static_cast<unsigned>(Capability::runtime_control); ++bit) {
        const auto capability = static_cast<Capability>(bit);
        if (capabilities.contains(capability)) {
          array.element(runtime::plugins::Capabilities::name(capability));
        }
      }
    });
  }

  static void digest(JsonWriter &writer, const runtime::plugins::PackageDigest &digest) {
    constexpr std::string_view digits = "0123456789abcdef";
    constexpr std::size_t characters_per_byte = 2;
    constexpr unsigned nibble_bits = 4;
    constexpr unsigned nibble_mask = 0xf;
    std::array<char, runtime::plugins::PackageDigest{}.size() * characters_per_byte> encoded{};
    std::size_t offset = 0;
    for (const auto byte : digest) {
      encoded[offset++] = digits[byte >> nibble_bits];
      encoded[offset++] = digits[byte & nibble_mask];
    }

    writer.value(std::string_view{encoded.data(), encoded.size()});
  }
};

}
