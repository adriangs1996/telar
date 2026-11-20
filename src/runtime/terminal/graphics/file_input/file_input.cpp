module telar.runtime.terminal.graphics.file_input;
import telar.base.ds;
import telar.base.text;
import telar.wire.vocabulary;

namespace telar::runtime {

  namespace {

    // The fields an atomic frame's control sets, each at most once.
    struct AtomicFrameFields {
      ds::Option<std::uint32_t> image;
      ds::Option<std::uint32_t> placement;
      ds::Option<std::uint32_t> width;
      ds::Option<std::uint32_t> height;
      ds::Option<std::uint32_t> depth;
      ds::Option<GraphicsInputMedium> medium;
      bool transmit = false;
      bool cursor_static = false;
      bool quiet = false;
    };

    // A flag the control may set once, to its one accepted value.
    bool acceptFlag(bool& seen, std::string_view value, std::string_view accepted) noexcept {
      if (seen || value != accepted) {
        return false;
      }

      seen = true;
      return true;
    }

    // A nonzero number the control may set once.
    bool acceptNumber(ds::Option<std::uint32_t>& destination, std::string_view value) noexcept {
      const auto number = kittyUnsigned<std::uint32_t>(value);
      if (destination || !number || *number == 0) {
        return false;
      }

      destination = *number;
      return true;
    }

    bool acceptMedium(ds::Option<GraphicsInputMedium>& medium, std::string_view value) noexcept {
      if (medium || (value != "s" && value != "f")) {
        return false;
      }

      medium = value == "s" ? GraphicsInputMedium::shared_memory : GraphicsInputMedium::file;
      return true;
    }

    // False for a key the frame refuses, or one it repeats.
    bool acceptField(AtomicFrameFields& found, const KittyControlField& field) noexcept {
      switch (field.key) {
      case 'a':
        return acceptFlag(found.transmit, field.value, "T");
      case 't':
        return acceptMedium(found.medium, field.value);
      case 'C':
        return acceptFlag(found.cursor_static, field.value, "1");
      case 'q':
        return acceptFlag(found.quiet, field.value, "2");
      case 'i':
        return acceptNumber(found.image, field.value);
      case 'p':
        return acceptNumber(found.placement, field.value);
      case 's':
        return acceptNumber(found.width, field.value);
      case 'v':
        return acceptNumber(found.height, field.value);
      case 'f':
        return acceptNumber(found.depth, field.value);
      default:
        return false;
      }
    }

    ds::Option<AtomicFrameControl> frameControl(const AtomicFrameFields& found) noexcept {
      constexpr std::uint32_t rgb_depth = 24;
      constexpr std::uint32_t rgba_depth = 32;
      if (!found.transmit || !found.cursor_static || !found.quiet || !found.medium || !found.image || !found.placement || !found.width || !found.height || !found.depth || (*found.depth != rgb_depth && *found.depth != rgba_depth)) {
        return ds::none;
      }

      const auto pixels = static_cast<std::uint64_t>(*found.width) * *found.height;
      const auto bytes_per_pixel = *found.depth == rgb_depth ? std::size_t{3} : std::size_t{4};
      if (pixels > std::numeric_limits<std::size_t>::max() / bytes_per_pixel) {
        return ds::none;
      }

      return AtomicFrameControl{
          .key = {.image_id = *found.image, .placement_id = *found.placement},
          .medium = *found.medium,
          .width = *found.width,
          .height = *found.height,
          .depth = static_cast<std::uint8_t>(*found.depth),
          .byte_count = static_cast<std::size_t>(pixels * bytes_per_pixel),
      };
    }

    // Records a field of a file transmission; false for a value it refuses. Other keys pass.
    bool acceptRangeField(KittyFileRange& range, bool& file, const KittyControlField& field) noexcept {
      switch (field.key) {
      case 'a':
        return field.value == "t" || field.value == "T";
      case 't':
        if (field.value != "f" && field.value != "t") {
          return false;
        }

        file = true;
        range.temporary = field.value == "t";
        return true;
      case 'm':
        return field.value == "0";
      case 'S':
      case 'O': {
        const auto number = kittyUnsigned<std::uint64_t>(field.value);
        if (!number) {
          return false;
        }

        if (field.key == 'S') {
          range.size = *number;
        } else {
          range.offset = *number;
        }

        return true;
      }
      default:
        return true;
      }
    }

  }

  ds::Option<AtomicFrameControl> AtomicFrameControl::parse(std::string_view text) noexcept {
    AtomicFrameFields found;
    KittyControlFields fields{text};

    while (const auto field = fields.next()) {
      if (!acceptField(found, *field)) {
        return ds::none;
      }
    }

    return fields.valid() ? frameControl(found) : ds::none;
  }

  ds::Option<AtomicFrame> AtomicFrame::at(std::string_view bytes, std::size_t start) noexcept {
    if (start > bytes.size()) {
      return ds::none;
    }

    const bool wrapped = textAfter(bytes, start).starts_with(cursor_save);
    const auto envelope = start + (wrapped ? cursor_save.size() : 0);
    if (!textAfter(bytes, envelope).starts_with(prefix)) {
      return ds::none;
    }

    const auto control_start = envelope + prefix.size();
    const auto terminator = bytes.find(command_terminator, control_start);
    if (terminator == std::string_view::npos || !textAfter(bytes, terminator).starts_with(suffix)) {
      return ds::none;
    }

    const auto end = terminator + suffix.size();
    if (wrapped && !textAfter(bytes, end).starts_with(cursor_restore)) {
      return ds::none;
    }

    const auto command = textPrefix(textAfter(bytes, control_start), terminator - control_start);
    const auto separator = command.find(';');
    if (separator == std::string_view::npos || separator + 1 == command.size()) {
      return ds::none;
    }

    const auto control = AtomicFrameControl::parse(textPrefix(command, separator));
    if (!control) {
      return ds::none;
    }

    return AtomicFrame{.start = start, .end = end + (wrapped ? cursor_restore.size() : 0), .command_start = control_start - introducer.size(), .command_end = terminator + command_terminator.size(), .encoded_name = textAfter(command, separator + 1), .control = *control, .cursor_wrapped = wrapped};
  }

  ds::Option<AtomicFrame> AtomicFrame::find(std::string_view bytes, std::size_t from) noexcept {
    for (auto start = bytes.find(prefix, from); start != std::string_view::npos; start = bytes.find(prefix, start + prefix.size())) {
      if (start >= cursor_save.size() && start - cursor_save.size() >= from && textAfter(bytes, start - cursor_save.size()).starts_with(cursor_save)) {
        if (auto wrapped = at(bytes, start - cursor_save.size())) {
          return wrapped;
        }
      }

      if (auto frame = at(bytes, start)) {
        return frame;
      }
    }

    return ds::none;
  }

  ds::Option<KittyFileRange> KittyFileRange::parse(std::string_view control) noexcept {
    KittyFileRange range;
    bool file = false;
    KittyControlFields fields{control};

    while (const auto field = fields.next()) {
      if (!acceptRangeField(range, file, *field)) {
        return ds::none;
      }
    }

    return file && fields.valid() ? ds::Option{range} : ds::none;
  }

  void GraphicsFileInput::feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, MediaInputSink& sink) {
    const auto text = textView(bytes);
    std::size_t emitted = 0;
    std::size_t search_from = 0;

    while (const auto parsed = nextCommand(text, search_from)) {
      const auto& [start, control, path] = *parsed;
      const auto command = text.substr(start + introducer.size(), search_from - terminator.size() - start - introducer.size());
      if (control.size() > control_capacity || !std::ranges::all_of(command, [](unsigned char byte) {
            return KittyFraming::content(byte);
          })) {
        continue;
      }

      const auto range = KittyFileRange::parse(control);
      if (!range) {
        continue;
      }

      sink.ingest(bytes.subspan(emitted, start - emitted));
      emitted = start;
      if (forward(Transmission{.control = control, .path = path, .range = *range, .limit = storage_limit}, sink)) {
        emitted = search_from;
      }
    }

    if (emitted != bytes.size()) {
      sink.ingest(bytes.subspan(emitted));
    }
  }

  void GraphicsFileInput::frame(std::span<const std::uint8_t> bytes, std::string_view ending, std::size_t storage_limit, MediaInputSink& sink) {
    if (forwardFrame(bytes, storage_limit, sink)) {
      return;
    }

    sink.ingest(bytes);
    sink.ingest(byteView(ending));
  }

  bool GraphicsFileInput::forwardFrame(std::span<const std::uint8_t> bytes, std::size_t storage_limit, MediaInputSink& sink) {
    const auto text = textView(bytes);
    if (text.size() < introducer.size() || text.front() != introducer.front() || text[2] != introducer.back()) {
      return false;
    }

    const auto body = textAfter(text, introducer.size());
    const auto separator = body.find(';');
    if (separator > control_capacity || !std::ranges::all_of(body, [](unsigned char byte) {
          return KittyFraming::content(byte);
        })) {
      return false;
    }

    const auto control = textPrefix(body, separator);
    const auto range = KittyFileRange::parse(control);

    return range && forward(Transmission{.control = control, .path = textAfter(body, separator + 1), .range = *range, .limit = storage_limit}, sink);
  }

  auto GraphicsFileInput::nextCommand(tbc::val_a<std::string_view> text, std::size_t& search_from) noexcept -> tbc::val_a<ds::Option<Command>> {
    for (;;) {
      const auto start = text.find(introducer, search_from);
      if (start == std::string_view::npos) {
        return ds::none;
      }

      const auto end = text.find(terminator, start + introducer.size());
      if (end == std::string_view::npos) {
        return ds::none;
      }

      search_from = end + terminator.size();
      const auto command = textPrefix(textAfter(text, start + introducer.size()), end - start - introducer.size());
      const auto separator = command.find(';');
      if (separator != std::string_view::npos && separator + 1 != command.size()) {
        return Command{.start = start, .control = textPrefix(command, separator), .path = textAfter(command, separator + 1)};
      }
    }
  }

  bool GraphicsFileInput::forward(const Transmission& request, MediaInputSink& sink) {
    const auto file = GraphicsChildFile::open(request.path);
    if (!file || request.range.offset > file->size) {
      return false;
    }

    GraphicsTemporaryPath temporary{*file};
    if (request.range.temporary && !temporary.authorize().empty()) {
      return false;
    }

    const auto available = file->size - request.range.offset;
    const auto length = request.range.size.valueOr(available);
    if (length == 0 || length > available || length > request.limit) {
      return false;
    }

    ds::Array<std::uint8_t, raw_chunk_bytes * chunks_per_read> raw; // NOLINT(cppcoreguidelines-pro-type-member-init): each read fills the batch it encodes, so zeroing 48 KiB per transmission is work no read needs
    ds::Array<char, chunk_capacity> chunk;                          // NOLINT(cppcoreguidelines-pro-type-member-init): encodeChunk writes the bytes a chunk sends before they are read
    std::uint64_t sent = 0;

    while (sent < length) {
      auto batch = raw.viewMut().first(static_cast<std::size_t>(std::min<std::uint64_t>(raw.size(), length - sent)));
      if (!readBatch(*file, batch, request.range.offset + sent)) {
        if (sent == 0) {
          return false;
        }

        constexpr std::string_view final_chunk = "\x1b_Gm=0;\x1b\\";

        sink.ingest(byteView(final_chunk));
        return true;
      }

      while (!batch.empty()) {
        const auto bytes = batch.first(std::min(batch.size(), raw_chunk_bytes));
        const auto control = sent == 0 ? request.control : std::string_view{};

        sent += bytes.size();
        sink.ingestEncodedChunk(encodeChunk(chunk.viewMut(), control, bytes, sent < length));
        batch = batch.subspan(bytes.size());
      }
    }

    return true;
  }

  bool GraphicsFileInput::readBatch(const GraphicsChildFile& file, std::span<std::uint8_t>& batch, std::uint64_t offset) noexcept {
    if (file.read(batch, offset)) {
      return true;
    }

    batch = batch.first(std::min(batch.size(), raw_chunk_bytes));
    return file.read(batch, offset);
  }

  tbc::val_a<std::span<const std::uint8_t>> GraphicsFileInput::encodeChunk(tbc::val_a<std::span<char>> chunk, std::string_view control, std::span<const std::uint8_t> raw, bool more) {
    std::size_t length = 0;
    const auto append = [&chunk, &length](std::string_view text) {
      std::ranges::copy(text, chunk.subspan(length).begin());
      length += text.size();
    };

    append(introducer);
    if (!control.empty()) {
      KittyControlFields fields{control};

      while (const auto field = fields.next()) {
        if (field->key == 't' || field->key == 'S' || field->key == 'O' || field->key == 'm') {
          continue;
        }

        append({&field->key, 1});
        append("=");
        append(field->value);
        append(",");
      }

      append("t=d,");
    }

    append(more ? "m=1;" : "m=0;");
    length += base64::encode(raw, chunk.subspan(length)).unwrap();
    append(terminator);
    return byteView(std::string_view{chunk.data(), length});
  }

  ImageAllocation::ImageAllocation(MediaAllocator<ConcurrentMemory>& memory, std::size_t byte_count) noexcept
      : memory_(memory),
        placeholder_(static_cast<std::uint8_t*>(memory_.allocate(placeholder_bytes, alignof(std::uint8_t)))) {
    if (placeholder_ == nullptr) {
      return;
    }

    if (!memory_.reserve(byte_count)) {
      memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
      return;
    }

    reserved_bytes_ = byte_count;
  }

  ImageAllocation::~ImageAllocation() {
    reset();
  }

  void ImageAllocation::reset() noexcept {
    if (reserved_bytes_ != 0) {
      memory_.release(std::exchange(reserved_bytes_, 0));
    }

    memory_.deallocate(std::exchange(placeholder_, nullptr), placeholder_bytes, alignof(std::uint8_t));
  }

  ImageAllocation::operator bool() const noexcept {
    return placeholder_ != nullptr;
  }

  bool ImageAllocation::adopt(MappedRegion& mapping) noexcept {
    if (placeholder_ == nullptr || mapping.bytes().size() != reserved_bytes_ || !memory_.adoptMapping(placeholder_, mapping)) {
      return false;
    }

    reserved_bytes_ = 0;
    return true;
  }

  std::span<const std::uint8_t> ImageAllocation::placeholder() const noexcept {
    // The allocator hands the placeholder as a pointer to its placeholder_bytes.
#pragma clang unsafe_buffer_usage begin
    return {static_cast<const std::uint8_t*>(placeholder_), placeholder_bytes};
#pragma clang unsafe_buffer_usage end
  }

  void ImageAllocation::release() noexcept {
    placeholder_ = nullptr;
  }

  bool MediaBatch::append(std::span<const Byte> bytes) noexcept {
    if (bytes.size() > byte_capacity - byte_count_) {
      return false;
    }

    auto* previous = event_count_ == 0 ? nullptr : std::get_if<Output>(&events_.atMut(event_count_ - 1));
    if (previous == nullptr && event_count_ == event_capacity) {
      return false;
    }

    if (!bytes.empty()) {
      std::ranges::copy(bytes, bytes_.viewMut().subspan(byte_count_).begin());
    }

    if (previous != nullptr) {
      previous->length += bytes.size();
    } else {
      events_.atMut(event_count_++) = Output{.offset = byte_count_, .length = bytes.size()};
    }

    byte_count_ += bytes.size();
    return true;
  }

  bool MediaBatch::resize(TerminalSize size) noexcept {
    if (event_count_ != 0 && std::holds_alternative<TerminalSize>(events_[event_count_ - 1])) {
      events_.atMut(event_count_ - 1) = size;
      return true;
    }

    if (event_count_ == event_capacity) {
      return false;
    }

    events_.atMut(event_count_++) = size;
    return true;
  }

  void MediaBatch::clear() noexcept {
    byte_count_ = 0;
    event_count_ = 0;
    reset_before_ = false;
    kitty_ = false;
  }

  auto MediaBatch::events() const noexcept -> std::span<const Event> {
    return std::span{events_}.first(event_count_);
  }

  std::span<const Byte> MediaBatch::bytes(Output output) const noexcept {
    return std::span{bytes_}.subspan(output.offset, output.length);
  }

  std::size_t MediaBatch::byteCount() const noexcept {
    return byte_count_;
  }

  bool MediaBatch::hasReadCapacity(std::size_t bytes) const noexcept {
    constexpr std::size_t reserved_events = 2;

    return bytes <= byte_capacity - byte_count_ && event_count_ + reserved_events <= event_capacity;
  }

}
