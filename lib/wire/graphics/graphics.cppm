export module telar.wire.graphics;

// Terminal graphics: images, placements and their snapshots.

import std;
import telar.wire.vocabulary;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
export extern "C++" {
  namespace telar {

    struct RequestGraphicsSnapshot {
      std::uint64_t pane_id{};
    };

    template <>
    struct MessageSchema<RequestGraphicsSnapshot>
        : Schema<Direction::client, ClientTag::request_graphics_snapshot, Field<&RequestGraphicsSnapshot::pane_id, NonzeroU64, "pane_id">> {};

    struct GraphicsCredit {
      std::uint64_t pane_id{};
      std::uint64_t bytes{};
    };

    template <>
    struct MessageSchema<GraphicsCredit>
        : Schema<Direction::client, ClientTag::graphics_credit, Field<&GraphicsCredit::pane_id, NonzeroU64, "pane_id">, Field<&GraphicsCredit::bytes, u64, "bytes">> {};

    struct ConfigureGraphics {
      bool shared{};
    };

    template <>
    struct MessageSchema<ConfigureGraphics>
        : Schema<Direction::client, ClientTag::configure_graphics, Field<&ConfigureGraphics::shared, BoolByte, "shared">> {};

    struct GraphicsSnapshot {
      GraphicsHeader header{};
      SnapshotPhase phase{};
    };

    template <>
    struct MessageSchema<GraphicsSnapshot>
        : Schema<Direction::server, ServerTag::graphics_snapshot, Field<&GraphicsSnapshot::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsSnapshot::phase, EnumByte<SnapshotPhase, 1>, "phase">> {};

    struct GraphicsImage {
      GraphicsHeader header{};
      ImageDescription image{};
    };

    template <>
    struct MessageSchema<GraphicsImage>
        : Schema<Direction::server, ServerTag::graphics_image, Field<&GraphicsImage::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsImage::image, ValueCodec<ImageDescription>, "image">> {};

    struct GraphicsImageChunk {
      GraphicsHeader header{};
      ImageKey key{};
      std::uint64_t offset{};
      std::span<const Byte> bytes;
    };

    template <>
    struct MessageSchema<GraphicsImageChunk>
        : Schema<Direction::server, ServerTag::graphics_image_chunk, Field<&GraphicsImageChunk::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsImageChunk::key, ValueCodec<ImageKey>, "key">, Field<&GraphicsImageChunk::offset, u64, "offset">, Field<&GraphicsImageChunk::bytes, SizedBytes<u32, 1048576, 1>, "bytes">> {};

    struct GraphicsPlacementMessage {
      GraphicsHeader header{};
      GraphicsPlacement placement{};
    };

    template <>
    struct MessageSchema<GraphicsPlacementMessage>
        : Schema<Direction::server, ServerTag::graphics_placement, Field<&GraphicsPlacementMessage::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsPlacementMessage::placement, ValueCodec<GraphicsPlacement>, "placement">> {};

    struct GraphicsDeleteImage {
      GraphicsHeader header{};
      ImageKey key{};
    };

    template <>
    struct MessageSchema<GraphicsDeleteImage>
        : Schema<Direction::server, ServerTag::graphics_delete_image, Field<&GraphicsDeleteImage::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsDeleteImage::key, ValueCodec<ImageKey>, "key">> {};

    struct GraphicsDeletePlacement {
      GraphicsHeader header{};
      ImageKey key{};
      std::uint64_t virtual_id{};
      std::uint32_t placement_id{};
    };

    template <>
    struct MessageSchema<GraphicsDeletePlacement>
        : Schema<Direction::server, ServerTag::graphics_delete_placement, Field<&GraphicsDeletePlacement::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsDeletePlacement::key, ValueCodec<ImageKey>, "key">, Field<&GraphicsDeletePlacement::virtual_id, u64, "virtual_id">, Field<&GraphicsDeletePlacement::placement_id, u32, "placement_id">> {};

    struct GraphicsSharedImage {
      GraphicsHeader header{};
      ImageDescription image{};
      std::string_view name;

      void validate() const;
    };

    template <>
    struct MessageSchema<GraphicsSharedImage>
        : Schema<Direction::server, ServerTag::graphics_shared_image, Field<&GraphicsSharedImage::header, ValueCodec<GraphicsHeader>, "header">, Field<&GraphicsSharedImage::image, ValueCodec<ImageDescription>, "image">, Field<&GraphicsSharedImage::name, Text32<31, false>, "name">> {};

  }
}
