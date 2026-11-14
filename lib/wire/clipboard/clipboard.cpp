module telar.wire.clipboard;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void validateClipboardContents(std::span<const ClipboardRepresentation> contents) {
    std::size_t size = 0;

    for (const auto& content : contents) {
      if (content.mime.empty() || content.mime.contains('\0') || content.data.size() > clipboard_content_limit - size) {
        throw EncodingError{"Invalid clipboard representation or aggregate size"};
      }

      size += content.data.size();
    }
  }

  void ClipboardDesktopRequest::validate() const {
    if (mimes.size() > 4 || contents.size() > 128) {
      throw EncodingError{"Invalid clipboard request bounds"};
    }

    validateClipboardContents(contents);
    if (!write && !contents.empty()) {
      throw EncodingError{"Clipboard read request contains write data"};
    }
  }

  void CompleteClipboardDesktop::validate() const {
    if (contents.size() > 4 || available.size() > 16 || (prepared && (!contents.empty() || !available.empty()))) {
      throw EncodingError{"Invalid clipboard completion phase or bounds"};
    }

    validateClipboardContents(contents);
    if (status != ClipboardDesktopStatus::success && (!contents.empty() || !available.empty() || remember)) {
      throw EncodingError{"Unsuccessful clipboard completion carries data"};
    }
  }

  void ReadRuntimeClipboard::validate() const {
    if (offset > runtime_clipboard_max_bytes || (transfer_id == 0 && offset != 0)) {
      throw EncodingError{"Invalid clipboard offset"};
    }
  }

  void RuntimeClipboardChunk::validate() const {
    if (mime.empty() || total_bytes > runtime_clipboard_max_bytes || offset > total_bytes ||
        bytes.size() > total_bytes - offset || (bytes.empty() && offset != total_bytes)) {
      throw EncodingError{"Invalid clipboard chunk"};
    }
  }

}
}
