// The plugins a configuration names: the overrides a client sets on them, the catalog of their
// packages for one configuration generation, and the pages a client lists or reads of it.
export module telar.gui.features.plugins:catalog;

import std;

import telar.tbc;
import telar.config.client;
import telar.plugins;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

// Interface: config/plugin_overrides.cppm
export {
  namespace telar::gui::features::plugins {

    class PluginOverrides {
    public:
      void set(const runtime::plugins::ConfiguredPlugin& specification, ds::Option<std::uint64_t> identity);

      [[nodiscard]] ds::Option<bool> requested(std::string_view path) const noexcept;

      void apply(runtime::plugins::Specifications& specifications) const noexcept;

      [[nodiscard]] bool disabled(std::uint64_t identity, std::span<const runtime::plugins::ConfiguredPlugin> specifications) const noexcept;

    private:
      struct Entry {
        runtime::plugins::ConfiguredPlugin specification;
        ds::Option<std::uint64_t> identity;
      };

      ds::Array<Entry, runtime::plugins::PackageLimits::configured> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: config/plugin_catalog.cppm
export {
  namespace telar::gui::features::plugins {

    class PluginCatalog {
    public:
      explicit PluginCatalog(std::uint64_t generation, std::span<const runtime::plugins::ConfiguredPlugin> specifications, std::span<const runtime::plugins::Package> packages, const PluginOverrides* overrides = nullptr) noexcept;

      [[nodiscard]] std::uint64_t generation() const noexcept;

      [[nodiscard]] std::size_t size() const noexcept;

      [[nodiscard]] const runtime::plugins::ConfiguredPlugin& specification(std::size_t index) const;

      [[nodiscard]] const runtime::plugins::Package* package(std::size_t index) const noexcept;

      [[nodiscard]] bool requestedEnabled(std::size_t index) const;

      [[nodiscard]] std::size_t find(std::string_view name) const;

      void validateGeneration(std::uint64_t requested) const;

      [[nodiscard]] const runtime::plugins::Package& resolve(const PluginActionDescription& requested) const;

    private:
      std::uint64_t generation_;
      std::span<const runtime::plugins::ConfiguredPlugin> specifications_;
      std::span<const runtime::plugins::Package> packages_;
      const PluginOverrides* overrides_;
    };

  }
}

// Interface: config/plugin_query.cppm
export {
  namespace telar::gui::features::plugins {

    struct PluginPage {
      std::string_view text;
      std::int64_t next = -1;
    };

    class PluginQuery {
    public:
      // A page is written into the output, region `a`.
      [[nodiscard]] static tbc::view<PluginPage, tbc::lt::a> list(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output);

      [[nodiscard]] static tbc::view<PluginPage, tbc::lt::a> get(const PluginCatalog& catalog, const ClientCommand& request, tbc::view<std::span<char>, tbc::lt::a> output);

    private:
      template <typename Entries>
      static void writePage(JsonWriter& writer, std::uint64_t generation, Entries&& entries);

      [[nodiscard]] static std::size_t page(std::int64_t value, std::size_t maximum);
      static void listEntry(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index);
      static void metadata(JsonWriter& writer, const PluginCatalog& catalog, std::size_t index);
      static void writeCapabilities(JsonWriter& writer, runtime::plugins::Capabilities capabilities);
      static void digest(JsonWriter& writer, const runtime::plugins::PackageDigest& digest);
    };

  }
}
