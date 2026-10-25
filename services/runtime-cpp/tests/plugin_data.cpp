#include "plugins/frame_writer.hpp"
#include "plugins/manifest.hpp"
#include "plugins/trust_store.hpp"

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

static void writeCapabilities(tap::FrameWriter &writer, tap::Capabilities capabilities) {
  for (unsigned index = 0; index <= static_cast<unsigned>(tap::Capability::runtime_control); ++index) {
    writer.boolean(capabilities.contains(static_cast<tap::Capability>(index)));
  }
}

extern "C" std::size_t plugin_data(unsigned mode, const Byte *input, std::size_t length, Byte *output, std::size_t capacity) {
  SystemAllocator memory;
  tap::FrameWriter writer{{output, capacity}};
  try {
    const std::string_view source{reinterpret_cast<const char *>(input), length};
    if (mode == 0) {
      const auto manifest = tap::Manifest::parse(memory, source);
      writer.text(manifest.id.view());
      writer.text(manifest.version.view());
      writer.text(manifest.entry.view());
      writer.text(manifest.source.view());
      writer.text(manifest.revision.view());
      writer.integer(static_cast<Byte>(manifest.action_count));
      for (const auto &action : std::span{manifest.actions}.first(manifest.action_count)) {
        writer.text(action.view());
      }
      writeCapabilities(writer, manifest.capabilities);
    } else {
      const auto trust = tap::TrustStore::parse(memory, source);
      writer.integer(static_cast<Byte>(trust.grants().size()));
      for (const auto &grant : trust.grants()) {
        writer.text(grant.plugin.view());
        writer.bytes(grant.digest);
        writeCapabilities(writer, grant.capabilities);
      }
    }
    return writer.finish().size();
  } catch (const std::exception &) {
    return 0;
  }
}
