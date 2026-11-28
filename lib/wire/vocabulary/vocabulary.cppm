export module telar.wire.vocabulary;

export import :wire;
export import :serializer;
export import :codec;
export import :value_codec;
export import :cells;
export import :messages;
export import :frame;

import telar.base.text.utf8;
import telar.vocabulary;

// Re-expose the shared vocabulary and UTF-8 error types that wire messages build on.
export namespace telar {
  using telar::Byte;
  using telar::EncodingError;
  using telar::EnvironmentEntry;
  using telar::EnvironmentMode;
  using telar::FailureCode;
  using telar::Launch;
  using telar::PaneKey;
  using telar::PaneKind;
  using telar::TerminalSize;
  using telar::validateUtf8;
}

export namespace telar::runtime {
  using telar::runtime::RequestError;
}
