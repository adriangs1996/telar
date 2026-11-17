module telar.gui.features.plugins;

import std;

import telar.tbc;
import telar.plugins;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;

namespace telar::gui::features::plugins {

  void PluginOverrides::set(const runtime::plugins::ConfiguredPlugin& specification, std::optional<std::uint64_t> identity) {
    for (auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == specification.path.view()) {
        entry.specification = specification;
        if (identity) {
          entry.identity = identity;
        }

        return;
      }
    }

    if (count_ == entries_.size()) {
      throw std::length_error{"TooManyPluginOverrides"};
    }

    entries_[count_] = {.specification = specification, .identity = identity};
    ++count_;
  }

  std::optional<bool> PluginOverrides::requested(std::string_view path) const noexcept {
    for (const auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.path.view() == path) {
        return entry.specification.enabled;
      }
    }

    return std::nullopt;
  }

  void PluginOverrides::apply(runtime::plugins::Specifications& specifications) const noexcept {
    for (auto& specification : std::span{specifications.entries}.first(specifications.count)) {
      if (const auto enabled = requested(specification.path.view())) {
        specification.enabled = *enabled;
      }
    }
  }

  bool PluginOverrides::disabled(std::uint64_t identity, std::span<const runtime::plugins::ConfiguredPlugin> specifications) const noexcept {
    for (const auto& entry : std::span{entries_}.first(count_)) {
      if (entry.specification.enabled || entry.identity != identity) {
        continue;
      }

      for (const auto& specification : specifications) {
        if (!specification.enabled && specification.path.view() == entry.specification.path.view()) {
          return true;
        }
      }
    }

    return false;
  }

  PluginCatalog::PluginCatalog(std::uint64_t generation, std::span<const runtime::plugins::ConfiguredPlugin> specifications, std::span<const runtime::plugins::Package> packages, const PluginOverrides* overrides) noexcept
      : generation_(generation),
        specifications_(specifications),
        packages_(packages),
        overrides_(overrides) {}

  std::uint64_t PluginCatalog::generation() const noexcept {
    return generation_;
  }

  std::size_t PluginCatalog::size() const noexcept {
    return specifications_.size();
  }

  const runtime::plugins::ConfiguredPlugin& PluginCatalog::specification(std::size_t index) const {
    if (index >= size()) {
      throw std::invalid_argument{"PluginNotConfigured"};
    }

    return specifications_[index];
  }

  const runtime::plugins::Package* PluginCatalog::package(std::size_t index) const noexcept {
    if (index >= size() || !specifications_[index].enabled) {
      return nullptr;
    }

    std::size_t loaded = 0;

    for (const auto& specification : specifications_.first(index)) {
      loaded += static_cast<std::size_t>(specification.enabled);
    }

    return loaded < packages_.size() ? &packages_[loaded] : nullptr;
  }

  bool PluginCatalog::requestedEnabled(std::size_t index) const {
    const auto& configured = specification(index);

    return overrides_ == nullptr ? configured.enabled : overrides_->requested(configured.path.view()).value_or(configured.enabled);
  }

  std::size_t PluginCatalog::find(std::string_view name) const {
    for (std::size_t index = 0; index < size(); ++index) {
      if (specifications_[index].path.view() == name) {
        return index;
      }

      if (const auto* loaded = package(index); loaded != nullptr && loaded->manifest.id.view() == name) {
        return index;
      }
    }

    throw std::invalid_argument{"PluginNotConfigured"};
  }

  void PluginCatalog::validateGeneration(std::uint64_t requested) const {
    if (requested != 0 && requested != generation_) {
      throw std::invalid_argument{"StaleConfiguration"};
    }
  }

  const runtime::plugins::Package& PluginCatalog::resolve(const PluginActionDescription& requested) const {
    for (const auto& package : packages_) {
      if (runtime::plugins::stableId(package.manifest.id.view()) != requested.plugin) {
        continue;
      }

      for (const auto& name : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
        if (runtime::plugins::stableId(name.view()) == requested.action) {
          return package;
        }
      }

      throw std::invalid_argument{"UnknownPluginAction"};
    }

    throw std::invalid_argument{"PluginNotConfigured"};
  }

  template <typename Entries>
  void PluginQuery::writePage(JsonWriter& writer, std::uint64_t generation, Entries&& entries) {
    writer.object([&](JsonWriter& object) {
      object.member("generation", generation);
      object.member("entries", [&](JsonWriter& value) {
        value.array(std::forward<Entries>(entries));
      });
    });
  }

  tbc::view<PluginPage, tbc::lt::a> PluginQuery::list(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = page(request.value, catalog.size());
    JsonWriter writer{output};

    writePage(writer, catalog.generation(), [&](JsonWriter& array) {
      if (index < catalog.size()) {
        array.element([&](JsonWriter& value) {
          listEntry(value, catalog, index);
        });
      }
    });

    return {.text = writer.view(), .next = index + 1 < catalog.size() ? static_cast<std::int64_t>(index + 1) : -1};
  }

  tbc::view<PluginPage, tbc::lt::a> PluginQuery::get(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output) {
    catalog.validateGeneration(request.target_id);
    const auto index = catalog.find(request.text);
    const auto* package = catalog.package(index);
    const auto count = package == nullptr ? 0 : package->manifest.action_count;
    const auto selected = page(request.value, count);
    JsonWriter writer{output};

    writePage(writer, catalog.generation(), [&](JsonWriter& array) {
      if (selected == 0) {
        array.element([&](JsonWriter& value) {
          metadata(value, catalog, index);
        });
      } else {
        array.element(package->manifest.actions[selected - 1].view());
      }
    });

    return {.text = writer.view(), .next = selected < count ? static_cast<std::int64_t>(selected + 1) : -1};
  }

  std::size_t PluginQuery::page(std::int64_t value, std::size_t maximum) {
    if (value < 0 || std::cmp_greater(value, maximum)) {
      throw std::invalid_argument{"InvalidPage"};
    }

    return static_cast<std::size_t>(value);
  }

  void PluginQuery::listEntry(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index) {
    const auto& specification = catalog.specification(index);
    const auto* package = catalog.package(index);

    writer.object([&](JsonWriter& object) {
      object.member("index", index);
      object.member("path", specification.path.view());
      object.member("id", package == nullptr ? std::nullopt : std::optional{package->manifest.id.view()});
      object.member("version", package == nullptr ? std::nullopt : std::optional{package->manifest.version.view()});
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
    });
  }

  void PluginQuery::metadata(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index) {
    const auto& specification = catalog.specification(index);
    const auto* package = catalog.package(index);

    writer.object([&](JsonWriter& object) {
      object.member("path", specification.path.view());
      object.member("requested_enabled", catalog.requestedEnabled(index));
      object.member("enabled", specification.enabled);
      if (package == nullptr) {
        object.member("id", nullptr);

        return;
      }

      const auto& manifest = package->manifest;

      object.member("id", manifest.id.view());
      object.member("version", manifest.version.view());
      object.member("entry", manifest.entry.view());
      object.member("source", manifest.source.view());
      object.member("revision", manifest.revision.view());
      object.member("digest", [&](JsonWriter& value) {
        digest(value, package->digest);
      });

      object.member("capabilities", [&](JsonWriter& value) {
        writeCapabilities(value, manifest.capabilities);
      });
    });
  }

  void PluginQuery::writeCapabilities(JsonWriter& writer, runtime::plugins::Capabilities capabilities) {
    using runtime::plugins::Capability;

    writer.array([&](JsonWriter& array) {
      for (unsigned bit = 0; bit <= static_cast<unsigned>(Capability::runtime_control); ++bit) {
        const auto capability = static_cast<Capability>(bit);
        if (capabilities.contains(capability)) {
          array.element(runtime::plugins::Capabilities::name(capability));
        }
      }
    });
  }

  void PluginQuery::digest(JsonWriter& writer, const runtime::plugins::PackageDigest& digest) {
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

}
