module telar.runtime.terminal.kitty;

import telar.platform.error;
import telar.runtime.terminal.ghostty;
import telar.runtime.host.descriptor_path;
import telar.base.ds;

namespace telar::runtime {

  ds::Option<KittyControlField> KittyControlFields::next() noexcept {
    if (remaining_.empty()) {
      return ds::none;
    }

    // Trimmed in place rather than with substr, which may throw.
    const auto comma = remaining_.find(',');
    auto field = remaining_;

    if (comma == std::string_view::npos) {
      remaining_ = {};
    } else {
      field.remove_suffix(field.size() - comma);
      remaining_.remove_prefix(comma + 1);
    }

    if (field.size() < 3 || field.find('=') != 1 || (comma != std::string_view::npos && remaining_.empty())) {
      valid_ = false;
      remaining_ = {};
      return ds::none;
    }

    auto value = field;

    value.remove_prefix(2);
    return KittyControlField{.key = field.front(), .value = value};
  }

  DisplayCells displayCells(const ImageDisplayRequest& request) noexcept {
    if (request.requested.columns != 0 && request.requested.rows != 0) {
      return request.requested;
    }

    if (request.cell_width == 0 || request.cell_height == 0) {
      return {};
    }

    const auto offset_x = std::min(request.offset_x, request.cell_width - 1);
    const auto offset_y = std::min(request.offset_y, request.cell_height - 1);
    auto width = request.width;
    auto height = request.height;

    if (request.requested.columns != 0) {
      width = saturatedDimension(static_cast<std::uint64_t>(request.cell_width) * request.requested.columns) - offset_x;
      height = scaledDimension(width, request.height, request.width);
    } else if (request.requested.rows != 0) {
      height = saturatedDimension(static_cast<std::uint64_t>(request.cell_height) * request.requested.rows) - offset_y;
      width = scaledDimension(height, request.width, request.height);
    }

    const auto occupied_width = saturatedDimension(static_cast<std::uint64_t>(width) + offset_x);
    const auto occupied_height = saturatedDimension(static_cast<std::uint64_t>(height) + offset_y);

    return DisplayCells{
        .columns = (occupied_width / request.cell_width) + static_cast<std::uint32_t>(occupied_width % request.cell_width != 0),
        .rows = (occupied_height / request.cell_height) + static_cast<std::uint32_t>(occupied_height % request.cell_height != 0),
    };
  }

  bool KittyFraming::canSkip(std::span<const std::uint8_t> bytes) const noexcept {
    // ranges::find over bytes is memchr.
    return state_ == State::ground && std::ranges::find(bytes, escape_byte) == bytes.end();
  }

  bool KittyFraming::canSkipCsi(std::span<const std::uint8_t> bytes) const noexcept {
    constexpr std::uint8_t parameter_first = 0x20;
    constexpr std::uint8_t parameter_last = 0x3f;
    constexpr std::uint8_t final_first = 0x40;
    constexpr std::uint8_t final_last = 0x7e;
    constexpr std::size_t minimum_csi_bytes = 3;
    if (state_ != State::ground || bytes.size() < minimum_csi_bytes || bytes[0] != escape_byte || bytes[1] != '[' || bytes.back() < final_first || bytes.back() > final_last) {
      return false;
    }

    return std::ranges::all_of(bytes.subspan(2, bytes.size() - minimum_csi_bytes), [](std::uint8_t byte) {
      return byte >= parameter_first && byte <= parameter_last;
    });
  }

  bool KittyFraming::touches(std::span<const std::uint8_t> bytes) noexcept {
    bool kitty = inside();
    std::size_t position = 0;

    while (advance(bytes, position)) {
      kitty = true;
    }

    return kitty;
  }

  ds::Option<KittyFraming::Transition> KittyFraming::advance(std::span<const std::uint8_t> bytes, std::size_t& position) noexcept {
    while (position < bytes.size()) {
      if (state_ == State::ground) {
        if (!skipToEscape(bytes, position)) {
          return ds::none;
        }

        continue;
      }

      if (const auto transition = step(bytes[position++])) {
        return transition;
      }
    }

    return ds::none;
  }

  bool KittyFraming::skipToEscape(std::span<const std::uint8_t> bytes, std::size_t& position) noexcept {
    // ranges::find over bytes is memchr.
    const auto rest = bytes.subspan(position);
    const auto escape = std::ranges::find(rest, escape_byte);
    if (escape == rest.end()) {
      position = bytes.size();
      return false;
    }

    position += static_cast<std::size_t>(escape - rest.begin()) + 1;
    state_ = State::escape;
    return true;
  }

  ds::Option<KittyFraming::Transition> KittyFraming::step(std::uint8_t byte) noexcept {
    if (state_ == State::escape) {
      state_ = afterEscape(byte);
      return ds::none;
    }

    if (ends(byte)) {
      const bool kitty = inside();

      state_ = byte == escape_byte ? State::escape : State::ground;
      if (kitty) {
        return Transition::ended;
      }

      return ds::none;
    }

    if (state_ == State::identify && content(byte)) {
      state_ = byte == 'G' ? State::kitty : State::other;
      if (inside()) {
        return Transition::started;
      }
    }

    return ds::none;
  }

  bool KittyCommandScanner::canSkip(std::span<const std::uint8_t> bytes) const noexcept {
    return framing_.canSkip(bytes);
  }

  bool KittyCommandScanner::canSkipCsi(std::span<const std::uint8_t> bytes) const noexcept {
    return framing_.canSkipCsi(bytes);
  }

  ds::Option<KittyCommandView> KittyCommandScanner::next(std::span<const std::uint8_t> bytes) noexcept {
    std::size_t position = 0;

    for (;;) {
      const auto start = position;
      const bool inside = framing_.inside();
      const auto transition = framing_.advance(bytes, position);
      if (!transition) {
        if (inside) {
          capture(bytes.subspan(start));
        }

        return ds::none;
      }

      if (*transition == KittyFraming::Transition::started) {
        control_length_ = 0;
        payload_length_ = 0;
        in_payload_ = false;
        truncated_ = false;
      } else {
        capture(bytes.subspan(start, position - start - 1));
        return KittyCommandView{.end = position, .control = {control_.data(), control_length_}, .payload_prefix = {payload_.data(), payload_length_}, .truncated = truncated_};
      }
    }
  }

  void KittyCommandScanner::capture(std::span<const std::uint8_t> bytes) noexcept {
    for (const auto byte : bytes) {
      if (!KittyFraming::content(byte)) {
        continue;
      }

      if (!in_payload_) {
        if (byte == ';') {
          in_payload_ = true;
        } else if (control_length_ < control_.size()) {
          control_.atMut(control_length_++) = static_cast<char>(byte);
        } else {
          truncated_ = true;
        }
      } else if (payload_length_ < payload_.size()) {
        payload_.atMut(payload_length_++) = static_cast<char>(byte);
      } else {
        return;
      }
    }
  }

  ds::Option<DisplayCells> KittyCursor::observe(const KittyCommandView& command, std::uint32_t cell_width, std::uint32_t cell_height) noexcept {
    const auto header = parse(command);
    if (!header || command.truncated || (header->image_id != 0 && header->image_number != 0)) {
      return ds::none;
    }

    if (pending_) {
      if (header->transmits()) {
        if (header->more) {
          return ds::none;
        }

        const auto first = *pending_;

        pending_.reset();
        return execute(first, cell_width, cell_height);
      }

      if (header->action == 'd') {
        pending_.reset();
      }
    } else if (header->transmits() && header->more) {
      pending_ = *header;
      return ds::none;
    }

    return execute(*header, cell_width, cell_height);
  }

  ds::Option<DisplayCells> KittyCursor::execute(const Header& header, std::uint32_t cell_width, std::uint32_t cell_height) noexcept {
    remember(header);
    if (header.action == 'd') {
      forget(header);
      return ds::none;
    }

    if ((header.action != 'T' && header.action != 'p') || header.stays) {
      return ds::none;
    }

    auto width = header.width;
    auto height = header.height;

    if (header.action == 'p') {
      const auto* known = find(header);
      if (known == nullptr) {
        return ds::none;
      }

      width = known->width;
      height = known->height;
    }

    if ((width == 0 || height == 0) && (header.requested.columns == 0 || header.requested.rows == 0)) {
      return ds::none;
    }

    const auto source_x = std::min(header.source_x, width);
    const auto source_y = std::min(header.source_y, height);
    const auto cells = displayCells({.width = std::min(header.source_width != 0 ? header.source_width : width, width - source_x), .height = std::min(header.source_height != 0 ? header.source_height : height, height - source_y), .requested = header.requested, .offset_x = header.offset_x, .offset_y = header.offset_y, .cell_width = cell_width, .cell_height = cell_height});

    return cells.columns != 0 && cells.rows != 0 ? ds::Option{cells} : ds::none;
  }

  void KittyCursor::remember(const Header& header) noexcept {
    if (!header.transmits() || header.width == 0 || header.height == 0 || (header.image_id == 0 && header.image_number == 0)) {
      return;
    }

    auto* slot = find(header);
    if (slot == nullptr) {
      slot = &sizes_.atMut(next_size_);
      next_size_ = (next_size_ + 1) % sizes_.size();
    }

    // Only the size of the header is kept.
    *slot = static_cast<const ImageSize&>(header);
  }

  void KittyCursor::forget(const Header& header) noexcept {
    if (header.target == 'A') {
      sizes_.fill({});
    } else if (header.target == 'I' || header.target == 'N') {
      if (auto* slot = find(header)) {
        *slot = {};
      }
    }
  }

  KittyCursor::ImageSize* KittyCursor::find(const Header& header) noexcept {
    for (auto& size : sizes_.viewMut()) {
      if ((header.image_id != 0 && size.image_id == header.image_id) || (header.image_id == 0 && header.image_number != 0 && size.image_number == header.image_number)) {
        return &size;
      }
    }

    return nullptr;
  }

  ds::Option<KittyCursor::Header> KittyCursor::parse(const KittyCommandView& command) noexcept {
    Header header;
    constexpr std::uint32_t png_format = 100;
    constexpr std::uint32_t rgba_format = 32;
    auto format = rgba_format;
    bool direct = true;
    bool compressed = false;
    KittyControlFields fields{command.control};

    while (const auto field = fields.next()) {
      const auto number = kittyUnsigned<std::uint32_t>(field->value).valueOr(0);

      switch (field->key) {
      case 'a':
        header.action = field->value.front();
        break;
      case 'i':
        header.image_id = number;
        break;
      case 'I':
        header.image_number = number;
        break;
      case 'd':
        header.target = field->value.front();
        break;
      case 'f':
        format = number;
        break;
      case 's':
        header.width = number;
        break;
      case 'v':
        header.height = number;
        break;
      case 'x':
        header.source_x = number;
        break;
      case 'y':
        header.source_y = number;
        break;
      case 'w':
        header.source_width = number;
        break;
      case 'h':
        header.source_height = number;
        break;
      case 'c':
        header.requested.columns = number;
        break;
      case 'r':
        header.requested.rows = number;
        break;
      case 'X':
        header.offset_x = number;
        break;
      case 'Y':
        header.offset_y = number;
        break;
      case 'C':
      case 'U':
        header.stays |= number == 1;
        break;
      case 'P':
        header.stays = true;
        break;
      case 'm':
        header.more = number != 0;
        break;
      case 't':
        direct = field->value.front() == 'd';
        break;
      case 'o':
        compressed = true;
        break;
      default:
        break;
      }
    }

    if (!fields.valid()) {
      return ds::none;
    }

    if (format == png_format) {
      header.width = 0;
      header.height = 0;
      if (direct && !compressed) {
        if (const auto size = pngSize(command.payload_prefix)) {
          header.width = (*size)[0];
          header.height = (*size)[1];
        }
      }
    }

    return header;
  }

  ds::Option<ds::Array<std::uint32_t, 2>> KittyCursor::pngSize(std::string_view encoded) noexcept {
    constexpr ds::Array<std::uint8_t, 8> signature{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    constexpr ds::Array<std::uint8_t, 4> header_chunk{'I', 'H', 'D', 'R'};
    constexpr std::size_t encoded_header_size = 32;
    constexpr std::size_t decoded_header_size = 24;
    constexpr std::size_t width_offset = 16;
    constexpr std::size_t height_offset = 20;
    constexpr std::size_t chunk_type_offset = 12;
    constexpr unsigned bits_per_byte = 8;
    ds::Array<std::uint8_t, decoded_header_size> bytes{};

    if (encoded.size() < encoded_header_size) {
      return ds::none;
    }

    // Trimmed in place rather than with substr, which may throw.
    encoded.remove_suffix(encoded.size() - encoded_header_size);
    if (base64::decode(encoded, bytes.viewMut()) != bytes.size() || !std::ranges::equal(bytes.view().first(signature.size()), signature.view()) || !std::ranges::equal(bytes.view().subspan(chunk_type_offset, header_chunk.size()), header_chunk.view())) {
      return ds::none;
    }

    const auto big_endian = [&](std::size_t offset) {
      std::uint32_t value = 0;

      for (const auto byte : bytes.view().subspan(offset, sizeof(std::uint32_t))) {
        value = (value << bits_per_byte) | byte;
      }

      return value;
    };

    return ds::Array{big_endian(width_offset), big_endian(height_offset)};
  }

  [[gnu::noinline]] void GraphicsCursor::feed(GhosttyTerminal terminal, std::span<const Byte> bytes, TerminalSize size) {
    if (scanner_.canSkip(bytes)) {
      ghostty_terminal_vt_write(terminal, bytes.data(), bytes.size());
      return;
    }

    feedCommands(terminal, bytes, size);
  }

  [[gnu::noinline]] void GraphicsCursor::feedCommands(GhosttyTerminal terminal, std::span<const Byte> bytes, TerminalSize size) {
    if (scanner_.canSkipCsi(bytes)) {
      ghostty_terminal_vt_write(terminal, bytes.data(), bytes.size());
      return;
    }

    auto remaining = bytes;

    while (const auto command = scanner_.next(remaining)) {
      ghostty_terminal_vt_write(terminal, remaining.data(), command->end);
      if (const auto cells = cursor_.observe(*command, size.cell_width_px, size.cell_height_px)) {
        advance(terminal, *cells, size);
      }

      remaining = remaining.subspan(command->end);
    }

    ghostty_terminal_vt_write(terminal, remaining.data(), remaining.size());
  }

  void GraphicsCursor::advance(GhosttyTerminal terminal, DisplayCells cells, TerminalSize size) {
    std::uint16_t x = 0;
    std::uint16_t y = 0;
    std::uint16_t top = 0;
    std::uint16_t bottom = 0;
    std::uint16_t left = 0;
    std::uint16_t right = 0;
    constexpr ds::Array keys{GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
    ds::Array<void*, keys.size()> values{&x, &y, &top, &bottom, &left, &right};

    checkGhostty(ghostty_terminal_get_multi(terminal, keys.size(), keys.data(), values.dataMut(), nullptr));

    const auto target_x = static_cast<std::uint64_t>(x) + cells.columns;
    const bool wraps = target_x >= size.cols;
    const auto requested_rows = static_cast<std::uint64_t>(cells.rows - 1) + static_cast<std::uint64_t>(wraps);
    const bool inside = y >= top && y <= bottom && x >= left && x <= right;
    const std::uint64_t rows_before_scroll = inside ? static_cast<std::uint64_t>(bottom) - y : 0;
    const auto rows = std::min<std::uint64_t>(requested_rows, rows_before_scroll + size.rows);

    for (std::uint64_t row = 0; row < rows; ++row) {
      if (ghostty_terminal_index(terminal) != GHOSTTY_SUCCESS) {
        break;
      }
    }

    const bool pending_wrap = false;
    const auto column = static_cast<std::uint16_t>(wraps ? 0 : target_x);

    checkGhostty(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CURSOR_PENDING_WRAP, &pending_wrap));
    checkGhostty(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CURSOR_X, &column));
  }

  ds::Option<GraphicsChildFile> GraphicsChildFile::open(std::string_view encoded_path) noexcept {
    ds::Array<std::uint8_t, PATH_MAX + 1> path{};
    const auto* decoded = decodeGraphicsName(encoded_path, path.viewMut());

    return openPath(decoded);
  }

  ds::Option<GraphicsChildFile> GraphicsChildFile::openDecoded(std::span<const std::uint8_t> decoded_path) noexcept {
    ds::Array<std::uint8_t, PATH_MAX + 1> path{};

    return openPath(copyGraphicsName(decoded_path, path.viewMut()));
  }

  ds::Option<GraphicsChildFile> GraphicsChildFile::openPath(const char* decoded) noexcept {
    if (decoded == nullptr || decoded[0] != '/') {
      return ds::none;
    }

    FileDescriptor file{::open(decoded, combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != ::getuid() || metadata.st_size < 0) {
      return ds::none;
    }

    return GraphicsChildFile{.descriptor = std::move(file), .size = static_cast<std::uint64_t>(metadata.st_size)};
  }

  bool GraphicsChildFile::read(std::span<std::uint8_t> bytes, std::uint64_t offset) const noexcept {
    std::size_t filled = 0;

    while (filled < bytes.size()) {
      if (offset > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max()) - filled) {
        return false;
      }

      const auto rest = bytes.subspan(filled);
      const auto count = ::pread(descriptor.get(), rest.data(), rest.size(), static_cast<off_t>(offset + filled));
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        return false;
      }

      filled += static_cast<std::size_t>(count);
    }

    return true;
  }

  // Each method below takes its object's mutex, which its caller must not hold. The pinned clang
  // rejects the negative capability, requires_capability(!mutex_), that would state so.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative"

  bool MappedImages::adopt(const void* placeholder, MappedRegion& pixels) noexcept {
    const std::scoped_lock lock{mutex_};

    if (placeholder == nullptr || !pixels) {
      return false;
    }

    Entry* available = nullptr;

    for (auto& entry : entries_.viewMut()) {
      if (entry.placeholder == placeholder) {
        return false;
      }

      if (entry.placeholder == nullptr && available == nullptr) {
        available = &entry;
      }
    }

    if (available == nullptr) {
      return false;
    }

    available->placeholder = placeholder;
    available->pixels = std::move(pixels);
    count_.fetch_add(1, std::memory_order_release);
    return true;
  }

  MappedRegion MappedImages::take(const void* placeholder) noexcept {
    if (count_.load(std::memory_order_acquire) == 0) {
      return {};
    }

    const std::scoped_lock lock{mutex_};

    for (auto& entry : entries_.viewMut()) {
      if (entry.placeholder == placeholder) {
        entry.placeholder = nullptr;
        count_.fetch_sub(1, std::memory_order_release);
        return std::move(entry.pixels);
      }
    }

    return {};
  }

  tbc::val_a<std::span<const std::uint8_t>> MappedImages::resolve(tbc::val_a<std::span<const std::uint8_t>> bytes) const noexcept {
    if (count_.load(std::memory_order_acquire) == 0) {
      return bytes;
    }

    const std::scoped_lock lock{mutex_};

    for (const auto& entry : entries_) {
      if (entry.placeholder == bytes.data()) {
        return entry.pixels.bytes();
      }
    }

    return bytes;
  }

  bool MediaBudget::reserve(std::size_t& pane_used, std::size_t pane_limit, std::size_t bytes) noexcept {
    const std::scoped_lock lock{mutex_};

    if (pane_used > pane_limit || bytes > pane_limit - pane_used || bytes > limit_ - used_) {
      return false;
    }

    pane_used += bytes;
    used_ += bytes;
    return true;
  }

  void MediaBudget::release(std::size_t& pane_used, std::size_t bytes) noexcept {
    const std::scoped_lock lock{mutex_};

    pane_used -= bytes;
    used_ -= bytes;
  }

  std::size_t MediaBudget::used() const noexcept {
    const std::scoped_lock lock{mutex_};

    return used_;
  }

  std::size_t MediaBudget::usedBy(const std::size_t& pane_used) const noexcept {
    const std::scoped_lock lock{mutex_};

    return pane_used;
  }

#pragma clang diagnostic pop

  namespace {

    bool inside(std::string_view directory, std::string_view path) noexcept {
      while (directory.size() > 1 && directory.back() == '/') {
        directory.remove_suffix(1);
      }

      return path.starts_with(directory) && path.size() > directory.size() && path[directory.size()] == '/';
    }

  }

  GraphicsTemporaryPath::~GraphicsTemporaryPath() {
    if (!armed_) {
      return;
    }

    struct stat opened{};
    struct stat current{};

    if (::fstat(file_.descriptor.get(), &opened) == 0 && ::lstat(path_.data(), &current) == 0 && S_ISREG(current.st_mode) && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino && current.st_uid == ::getuid()) {
      ::unlink(path_.data());
    }
  }

  tbc::val_static<std::string_view> GraphicsTemporaryPath::authorize() noexcept {
#if !defined(__APPLE__) && !defined(__linux__)
    return "EINVAL: unsupported medium";
#endif
    try {
      path_ = descriptorPath(file_.descriptor.get());
    } catch (const SystemError&) {
      return "EINVAL: invalid data";
    }

    const std::string_view path{path_.data()};
    bool temporary = inside("/tmp", path) || inside("/dev/shm", path);

#ifdef __APPLE__
    temporary |= inside("/private/tmp", path);
#endif
    if (!temporary) {
      ds::Array<char, PATH_MAX + 1> canonical{};
      // Asked for before the lookup, which any later call into the project may replace.
      auto* resolved = canonical.dataMut();
      const auto* environment = std::getenv("TMPDIR"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment
      if (environment != nullptr && std::string_view{environment}.size() <= PATH_MAX && ::realpath(environment, resolved) != nullptr) {
        temporary = inside(canonical.data(), path);
      }
    }

    if (!temporary) {
      return "EINVAL: temporary file not in temp dir";
    }

    if (!path.contains("tty-graphics-protocol")) {
      return "EINVAL: temporary file not named correctly";
    }

    armed_ = true;
    return {};
  }

}
