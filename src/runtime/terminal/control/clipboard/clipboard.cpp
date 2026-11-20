module telar.runtime.terminal.control.clipboard;

import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime::control {

  std::string_view clipboardStatusName(ClipboardStatus status) noexcept {
    switch (status) {
    case ClipboardStatus::ok:
      return "OK";
    case ClipboardStatus::done:
      return "DONE";
    case ClipboardStatus::data:
      return "DATA";
    case ClipboardStatus::denied:
      return "EPERM";
    case ClipboardStatus::invalid:
      return "EINVAL";
    case ClipboardStatus::too_large:
      return "EFBIG";
    case ClipboardStatus::busy:
      return "EBUSY";
    case ClipboardStatus::io_error:
      return "EIO";
    case ClipboardStatus::unsupported:
      return "ENOSYS";
    }

    return "EINVAL";
  }

  namespace {

    // The operation a metadata's type names.
    ds::Option<ClipboardOperation> clipboardOperation(std::string_view type) noexcept {
      if (type == "read") {
        return ClipboardOperation::read;
      }

      if (type == "write") {
        return ClipboardOperation::write;
      }

      if (type == "wdata") {
        return ClipboardOperation::data;
      }

      if (type == "walias") {
        return ClipboardOperation::alias;
      }

      return ds::none;
    }

    // What the desktop's answer makes of a request.
    constexpr ClipboardStatus desktopResult(ClipboardDesktopStatus status) noexcept {
      if (status == ClipboardDesktopStatus::success) {
        return ClipboardStatus::done;
      }

      if (status == ClipboardDesktopStatus::denied) {
        return ClipboardStatus::denied;
      }

      return status == ClipboardDesktopStatus::unsupported ? ClipboardStatus::unsupported : ClipboardStatus::io_error;
    }

    constexpr bool idCharacter(char byte) noexcept {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '+' || byte == '.';
    }

  }

  ds::Option<ClipboardMetadata> ClipboardMetadata::parse(std::string_view input) {
    std::string_view type;
    std::string_view location;
    std::string_view id;
    std::string_view mime;
    std::string_view password;
    std::string_view name;

    while (true) {
      const auto colon = input.find(':');
      const auto record = input.substr(0, colon);
      const auto equal = record.find('=');
      if (equal == std::string_view::npos) {
        return ds::none;
      }

      const auto key = record.substr(0, equal);
      const auto value = record.substr(equal + 1);

      if (key == "type") {
        type = value;
      } else if (key == "loc") {
        location = value;
      } else if (key == "id") {
        id = value;
      } else if (key == "mime") {
        mime = value;
      } else if (key == "pw") {
        password = value;
      } else if (key == "name") {
        name = value;
      }

      if (colon == std::string_view::npos) {
        break;
      }

      input.remove_prefix(colon + 1);
    }

    const auto operation = clipboardOperation(type);
    if (!operation) {
      return ds::none;
    }

    ClipboardMetadata result;

    result.operation = *operation;
    result.primary = location == "primary";
    ds::Array<char, maximum_id> sanitized{};
    std::size_t size = 0;

    for (const auto byte : id) {
      if (size == sanitized.size()) {
        break;
      }

      if (idCharacter(byte)) {
        sanitized.atMut(size++) = byte;
      }
    }

    result.id.assign({sanitized.data(), size});
    result.invalid_values = decode(mime, result.mime) != MetadataValue::valid || decode(name, result.name) != MetadataValue::valid;
    // Oversized passwords cannot match a bounded grant. Their contents do not
    // need to be retained, but malformed short passwords still invalidate it.
    result.invalid_values |= decode(password, result.password) == MetadataValue::invalid;
    result.invalid_values |= result.mime.view().contains('\0');
    return result;
  }

  template <std::size_t Capacity>
  MetadataValue ClipboardMetadata::decode(std::string_view encoded, FixedText<Capacity>& destination) {
    if (encoded.size() > (Capacity + 2) / 3 * 4) {
      return MetadataValue::overflow;
    }

    ds::Array<std::uint8_t, Capacity + 2> output;
    const auto length = base64::decode<base64::Padding::required>(encoded, output.viewMut());
    if (!length) {
      return MetadataValue::invalid;
    }

    if (*length > Capacity) {
      return MetadataValue::overflow;
    }

    const auto decoded = textView(output.view().first(*length));

    try {
      validateUtf8(decoded);
    } catch (const EncodingError&) {
      return MetadataValue::invalid;
    }

    destination.assign(decoded);
    return MetadataValue::valid;
  }

  void ClipboardGrants::grant(std::string_view password, ClipboardRoute route, bool write, bool once) {
    if (password.empty() || password.size() > ClipboardMetadata::maximum_password) {
      return;
    }

    Entry* entry = nullptr;

    for (auto& candidate : entries_.viewMut().first(count_)) {
      if (candidate.route == route && constantTimeEqual(candidate.password.view(), password)) {
        entry = &candidate;
        entry->once &= once;
        break;
      }
    }

    if (entry == nullptr) {
      if (count_ == entries_.size()) {
        std::ranges::move(entries_.viewMut().subspan(1), entries_.viewMut().begin());
        --count_;
      }

      entry = &entries_.atMut(count_++);
      entry->password.assign(password);
      entry->route = route;
      entry->read = false;
      entry->write = false;
      entry->once = once;
    }

    if (write) {
      entry->write = true;
    } else {
      entry->read = true;
    }
  }

  ds::Option<ClipboardRoute> ClipboardGrants::use(std::string_view password, bool write) {
    ds::Option<std::size_t> matching;

    for (std::size_t index = 0; index < count_; ++index) {
      const auto& entry = entries_[index];
      if (!constantTimeEqual(entry.password.view(), password)) {
        continue;
      }

      matching = index;
      if (write ? entry.write : entry.read) {
        break;
      }
    }

    if (!matching) {
      return ds::none;
    }

    const auto index = *matching;
    const auto& entry = entries_[index];
    const bool permitted = write ? entry.write : entry.read;
    const auto route = entry.route;

    if (entry.once) {
      std::ranges::move(entries_.viewMut().first(count_).subspan(index + 1), entries_.viewMut().subspan(index).begin());
      --count_;
    }

    return permitted ? ds::Option{route} : ds::none;
  }

  void ClipboardGrants::retain(std::span<const ClipboardRoute> routes) noexcept {
    std::size_t kept = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (std::ranges::contains(routes, entries_[index].route)) {
        if (kept != index) {
          entries_.atMut(kept) = entries_[index];
        }

        ++kept;
      }
    }

    count_ = kept;
  }

  void ClipboardGrants::clear() noexcept {
    count_ = 0;
  }

  auto ClipboardGrants::password() -> FixedText<password_length> {
    // A power of two, so that masking a random byte picks each character alike.
    constexpr std::size_t alphabet_size = 64;
    constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    static_assert(alphabet.size() == alphabet_size);
    ds::Array<std::uint8_t, password_length> random{};

    randomBytes(random.dataMut(), random.size());
    ds::Array<char, password_length> output{};

    for (std::size_t index = 0; index < output.size(); ++index) {
      output.atMut(index) = alphabet[random[index] & (alphabet.size() - 1)];
    }

    FixedText<password_length> result;

    result.assign({output.data(), output.size()});
    return result;
  }

  ClipboardWrite::ClipboardWrite(tbc::mut_a<ConcurrentMemory> memory, ClipboardMetadata request, std::size_t limit)
      : metadata(std::move(request)),
        memory_(memory),
        spool_(memory),
        limit_(limit) {}

  ds::Option<ClipboardStatus> ClipboardWrite::selectEntry(std::string_view mime) {
    if (current_ && entries_[*current_].mime.view() == mime) {
      return ds::none;
    }

    if (finishCurrent() != ClipboardStatus::ok) {
      return ClipboardStatus::invalid;
    }

    current_.reset();
    for (std::size_t index = 0; index < entry_count_; ++index) {
      if (entries_[index].mime.view() == mime) {
        current_ = index;
        break;
      }
    }

    if (!current_) {
      // Representations past the limit are dropped, and the write goes on without them.
      if (entry_count_ == maximum_mimes) {
        return ClipboardStatus::ok;
      }

      current_ = entry_count_++;
      entries_.atMut(*current_).mime.assign(mime);
    }

    auto& entry = entries_.atMut(*current_);

    entry.offset = spool_.size();
    entry.length = 0;
    return ds::none;
  }

  ClipboardStatus ClipboardWrite::data(const ClipboardMetadata& request, std::string_view encoded) {
    if (const auto selected = selectEntry(request.mime.view())) {
      return *selected;
    }

    for (std::size_t index = 0; index < encoded.size(); ++index) {
      const auto byte = encoded[index];
      if (byte != '=' && !base64::alphabet.contains(byte)) {
        return ClipboardStatus::invalid;
      }

      group_.atMut(group_size_++) = byte;
      if (group_size_ != group_.size()) {
        continue;
      }

      ds::Array<std::uint8_t, 3> decoded{};
      const auto count = base64::decode<base64::Padding::required>({group_.dataMut(), group_.size()}, decoded.viewMut());
      if (!count || (*count != decoded.size() && index + 1 != encoded.size())) {
        return ClipboardStatus::invalid;
      }

      if (*count > limit_ - spool_.size()) {
        return ClipboardStatus::too_large;
      }

      reserve(*count);
      spool_.extend(decoded.view().first(*count));
      group_size_ = 0;
    }

    return ClipboardStatus::ok;
  }

  ClipboardStatus ClipboardWrite::alias(const ClipboardMetadata& request, std::string_view encoded) {
    const auto mime = request.mime.view();
    ds::Vec<std::uint8_t, ConcurrentMemory> decoded{memory_};

    if (encoded.size() / 4 * 3 > limit_) {
      return ClipboardStatus::too_large;
    }

    decoded.resize(encoded.size() / 4 * 3);
    const auto length = base64::decode<base64::Padding::required>(encoded, decoded.viewMut());
    if (!length) {
      return ClipboardStatus::invalid;
    }

    auto remaining = textView(decoded.view().first(*length));

    try {
      validateUtf8(remaining);
    } catch (const EncodingError&) {
      return ClipboardStatus::invalid;
    }

    while (const auto name = token(remaining)) {
      if (name->contains('\0')) {
        return ClipboardStatus::invalid;
      }

      if (name->size() > ClipboardMetadata::maximum_mime) {
        continue;
      }

      auto index = alias_count_;

      for (std::size_t candidate = 0; candidate < alias_count_; ++candidate) {
        if (aliases_[candidate].name.view() == *name) {
          index = candidate;
          break;
        }
      }

      if (index == alias_count_) {
        if (alias_count_ == maximum_aliases) {
          continue;
        }

        aliases_.atMut(alias_count_++).name.assign(*name);
      }

      aliases_.atMut(index).target.assign(mime);
    }

    return ClipboardStatus::ok;
  }

  ClipboardStatus ClipboardWrite::commit() {
    if (finishCurrent() != ClipboardStatus::ok) {
      return ClipboardStatus::invalid;
    }

    current_.reset();
    content_count_ = 0;
    for (const auto& entry : std::span{entries_}.first(entry_count_)) {
      contents_.atMut(content_count_++) = {.mime = entry.mime.view(), .data = std::span<const std::uint8_t>{spool_}.subspan(entry.offset, entry.length)};
    }

    for (const auto& alias : std::span{aliases_}.first(alias_count_)) {
      ds::Option<std::span<const std::uint8_t>> target;

      for (const auto& content : std::span{contents_}.first(content_count_)) {
        if (content.mime == alias.target.view()) {
          target = content.data;
          break;
        }
      }

      if (!target) {
        continue;
      }

      bool replaced = false;

      for (auto& content : contents_.viewMut().first(content_count_)) {
        if (content.mime == alias.name.view()) {
          content.data = *target;
          replaced = true;
          break;
        }
      }

      if (!replaced) {
        contents_.atMut(content_count_++) = {.mime = alias.name.view(), .data = *target};
      }
    }

    // The desktop transport and platform clipboard have the same aggregate
    // budget, including alias representations that the desktop must copy.
    std::size_t total = 0;

    for (const auto& content : contents()) {
      if (content.data.size() > limit_ - total) {
        return ClipboardStatus::too_large;
      }

      total += content.data.size();
    }

    return ClipboardStatus::ok;
  }

  std::span<const ClipboardContentView> ClipboardWrite::contents() const noexcept {
    return std::span{contents_}.first(content_count_);
  }

  ds::Option<std::string_view> ClipboardWrite::token(std::string_view& remaining) noexcept {
    constexpr std::string_view whitespace = " \t\n\r\f\v";
    const auto first = remaining.find_first_not_of(whitespace);
    if (first == std::string_view::npos) {
      remaining = {};
      return ds::none;
    }

    remaining.remove_prefix(first);
    const auto end = remaining.find_first_of(whitespace);
    const auto result = textPrefix(remaining, end);

    remaining = end == std::string_view::npos ? std::string_view{} : textAfter(remaining, end + 1);
    return result;
  }

  ClipboardStatus ClipboardWrite::finishCurrent() noexcept {
    if (group_size_ != 0) {
      return ClipboardStatus::invalid;
    }

    if (current_) {
      entries_.atMut(*current_).length = spool_.size() - entries_[*current_].offset;
    }

    return ClipboardStatus::ok;
  }

  void ClipboardWrite::reserve(std::size_t count) {
    if (count > spool_.capacity() - spool_.size()) {
      spool_.reserve(std::min(limit_, std::max({spool_.size() + count, initial_capacity, spool_.capacity() * 2})));
    }
  }

  void clipboardBase64(Reply<ConcurrentMemory>& reply, std::span<const std::uint8_t> input) {
    constexpr std::size_t raw_chunk_bytes = 3072;
    ds::Array<char, raw_chunk_bytes / 3 * 4> encoded; // NOLINT(cppcoreguidelines-pro-type-member-init): encode writes the bytes a chunk appends before they are read, so zeroing 4 KiB per reply is work no read needs

    while (!input.empty()) {
      const auto count = std::min(input.size(), raw_chunk_bytes);
      const auto size = base64::encode(input.first(count), encoded.viewMut());
      if (!size) {
        throw std::logic_error{"Clipboard encoder capacity invariant failed"};
      }

      reply.append({encoded.data(), *size});
      input = input.subspan(count);
    }
  }

  void clipboardBase64(Reply<ConcurrentMemory>& reply, std::string_view input) {
    clipboardBase64(reply, byteView(input));
  }

  void clipboardPacket(Reply<ConcurrentMemory>& reply, const ClipboardPacket& packet) {
    reply.append(packet.operation == ClipboardOperation::read ? "\x1b]5522;type=read:status=" : "\x1b]5522;type=write:status=");
    reply.append(clipboardStatusName(packet.status));
    if (packet.primary) {
      reply.append(":loc=primary");
    }

    if (!packet.id.empty()) {
      reply.append(":id=");
      reply.append(packet.id);
    }

    if (packet.mime) {
      reply.append(":mime=");
      clipboardBase64(reply, *packet.mime);
    }

    if (packet.password) {
      reply.append(":pw=");
      clipboardBase64(reply, *packet.password);
    }

    if (!packet.payload.empty()) {
      reply.append(";");
      clipboardBase64(reply, packet.payload);
    }

    reply.append(packet.ending == Ending::bell ? "\a" : "\x1b\\");
  }

  void clipboardReadSuccess(Reply<ConcurrentMemory>& reply, const ClipboardPacket& request, std::span<const ClipboardContentView> contents, std::span<const std::string_view> available, bool listing) {
    auto packet = request;

    packet.operation = ClipboardOperation::read;
    packet.status = ClipboardStatus::ok;
    clipboardPacket(reply, packet);
    packet.primary = false;
    if (listing) {
      ds::Array<std::uint8_t, clipboard_chunk_bytes> joined; // NOLINT(cppcoreguidelines-pro-type-member-init): the listing writes the bytes it sends before they are read, so zeroing 4 KiB per listing is work no read needs
      std::size_t length = 0;

      for (const auto mime : available) {
        const auto separator = length == 0 ? 0U : 1U;
        if (mime.size() + separator + 1 > joined.size() - length) {
          break;
        }

        if (separator != 0) {
          joined.atMut(length++) = ' ';
        }

        std::ranges::copy(mime, joined.viewMut().subspan(length).begin());
        length += mime.size();
      }

      if (length != 0) {
        joined.atMut(length++) = '\n';
      }

      packet.status = ClipboardStatus::data;
      packet.mime = ".";
      packet.payload = std::span<const std::uint8_t>{joined}.first(length);
      clipboardPacket(reply, packet);
    }

    for (const auto& content : contents) {
      auto remaining = content.data;

      while (!remaining.empty()) {
        const auto count = std::min(remaining.size(), clipboard_chunk_bytes);

        packet.status = ClipboardStatus::data;
        packet.mime = content.mime;
        packet.payload = remaining.first(count);
        clipboardPacket(reply, packet);
        remaining = remaining.subspan(count);
      }
    }

    packet.status = ClipboardStatus::done;
    packet.mime.reset();
    packet.payload = {};
    clipboardPacket(reply, packet);
  }

  Clipboard::Clipboard(ConcurrentMemory& memory)
      : memory_(memory),
        decoded_(memory),
        replies_{.replies{Reply<ConcurrentMemory>{memory}, Reply<ConcurrentMemory>{memory}}} {}

  void Clipboard::routes(std::span<const ClipboardRoute> routes, ds::Option<ClipboardRoute> preferred) {
    if (routes.size() > routes_.size()) {
      throw std::logic_error{"Too many clipboard client routes"};
    }

    std::ranges::copy(routes, routes_.viewMut().begin());
    route_count_ = routes.size();
    preferred_ = preferred;
    grants_.retain(routes);
    if (pending_ && !live(pending_->route)) {
      cancelPending();
      finish(ClipboardStatus::denied);
    }
  }

  void Clipboard::traditional(std::string_view payload, const Policy& policy) {
    const auto separator = payload.find(';');
    // npos, a missing separator, is past 1 too.
    if (separator > 1) {
      return;
    }

    const char kind = separator == 0 ? 'c' : payload.front();
    const char selection = kind == 'p' || kind == 's' ? kind : 'c';
    const auto encoded = payload.substr(separator + 1);
    const bool read = encoded == "?";
    const auto access = read ? policy.clipboard_read : policy.clipboard_write;
    if (access == Access::deny || pending_ || cancellation_ || replies_.count != 0 || !preferred_) {
      return;
    }

    try {
      if (!read && !decode<base64::Padding::optional>(encoded)) {
        return;
      }

      pending_ = ds::makeBox<Pending>(memory_, memory_);
      auto& request = pending_.getMut();

      request.traditional = true;
      request.selection = selection;
      request.write = !read;
      // Application OSC52 reads use the standard desktop clipboard while
      // echoing the requested selection name in the terminal response.
      request.metadata.primary = !read && (selection == 'p' || selection == 's');
      request.metadata.operation = read ? ClipboardOperation::read : ClipboardOperation::write;
      request.route = *preferred_;
      request.prompt = access == Access::ask;
      request.mimes.atMut(request.mime_count++).assign("text/plain");
      if (!read) {
        request.text.clear();
        request.text.extend(decoded_.view());
      }
    } catch (const std::bad_alloc&) {
      pending_.reset();
    }
  }

  void Clipboard::kitty(std::string_view payload, Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply) {
    const auto separator = payload.find(';');
    const auto metadata = ClipboardMetadata::parse(payload.substr(0, separator));
    if (!metadata) {
      return;
    }

    const auto data = separator == std::string_view::npos ? std::string_view{} : payload.substr(separator + 1);

    if (metadata->invalid_values) {
      if (transaction_ && (metadata->operation == ClipboardOperation::data || metadata->operation == ClipboardOperation::alias)) {
        abort(ClipboardStatus::invalid, ending, reply);
      }

      return;
    }

    const bool had_pending = pending_.hasValue();

    try {
      switch (metadata->operation) {
      case ClipboardOperation::read:
        read(*metadata, data, ending, policy, reply);
        return;
      case ClipboardOperation::write:
        transaction_.reset();
        if (policy.clipboard_write == Access::deny) {
          status(*metadata, ClipboardStatus::denied, ending, reply);
        } else {
          transaction_ = ds::makeBox<ClipboardWrite>(memory_, memory_, *metadata, maximum_bytes);
        }

        return;
      case ClipboardOperation::data:
      case ClipboardOperation::alias:
        transactionChunk(*metadata, data, ending, policy, reply);
        return;
      }
    } catch (const std::bad_alloc&) {
      if (!had_pending) {
        pending_.reset();
      }

      if (transaction_) {
        abort(ClipboardStatus::io_error, ending, reply);
      } else {
        status(*metadata, ClipboardStatus::io_error, ending, reply);
      }
    }
  }

  void Clipboard::transactionChunk(const ClipboardMetadata& metadata, std::string_view data, Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply) {
    if (!transaction_) {
      return;
    }

    if (metadata.operation == ClipboardOperation::data && metadata.mime.view().empty()) {
      commit(ending, policy, reply);
      return;
    }

    if (metadata.mime.view().empty()) {
      abort(ClipboardStatus::invalid, ending, reply);
      return;
    }

    const auto result = metadata.operation == ClipboardOperation::data ? transaction_.getMut().data(metadata, data) : transaction_.getMut().alias(metadata, data);
    if (result != ClipboardStatus::ok) {
      abort(result, ending, reply);
    }
  }

  ds::Option<ClipboardDesktopRequest> Clipboard::request(std::uint64_t pane, std::uint64_t generation) {
    if (!pending_ || pending_->announced) {
      return ds::none;
    }

    auto& pending = pending_.getMut();

    pending.ticket = {.pane_id = pane, .pane_generation = generation, .client_generation = pending.route.generation, .nonce = pending.nonce};
    const auto contents = pending.prepareViews();

    return ClipboardDesktopRequest{
        .ticket = pending.ticket,
        .write = pending.write,
        .primary = pending.metadata.primary,
        .prompt = pending.prompt,
        .listing = pending.listing,
        .rememberable = !pending.traditional && !pending.metadata.name.view().empty() && !pending.metadata.password.view().empty(),
        .name = pending.metadata.name.view(),
        .mimes = std::span{pending.mime_views}.first(pending.mime_count),
        .contents = std::span{pending.content_views}.first(contents),
    };
  }

  ds::Option<ClipboardRoute> Clipboard::route() const noexcept {
    return pending_ ? ds::Option{pending_->route} : ds::none;
  }

  void Clipboard::announced() noexcept {
    if (pending_) {
      pending_.getMut().announced = true;
    }
  }

  bool Clipboard::complete(ClipboardRoute sender, const CompleteClipboardDesktop& completion) {
    if (!pending_ || !pending_->announced || pending_->route != sender || pending_->ticket != completion.ticket || !live(sender)) {
      return false;
    }

    completion.validate();
    if (completion.prepared) {
      if (pending_->committed) {
        return false;
      }

      if (completion.status != ClipboardDesktopStatus::success) {
        if (pending_->traditional && !pending_->write && completion.status == ClipboardDesktopStatus::denied) {
          ReplyBuilder builder{replies_};

          builder.reply().append("\x1b]52;");
          builder.reply().append({&pending_->selection, 1});
          builder.reply().append(";\x1b\\");
          builder.commit();
        }

        finish(desktopResult(completion.status));
        return true;
      }

      pending_.getMut().prepared = true;
      pending_.getMut().remember = completion.remember;
      return true;
    }

    if (!pending_->committed) {
      return false;
    }

    try {
      completeResult(sender, completion);
    } catch (const std::bad_alloc&) {
      finish(ClipboardStatus::io_error);
    }

    return true;
  }

  void Clipboard::completeResult(ClipboardRoute sender, const CompleteClipboardDesktop& completion) {
    const auto result = desktopResult(completion.status);
    const auto& pending = *pending_;

    if (result != ClipboardStatus::done) {
      finish(result);
      return;
    }

    if (pending.remember && !pending.metadata.name.view().empty() && !pending.metadata.password.view().empty()) {
      grants_.grant(pending.metadata.password.view(), sender, pending.write, false);
    }

    ReplyBuilder builder{replies_};
    auto& asynchronous_reply = builder.reply();

    if (pending.traditional) {
      if (!pending.write) {
        traditionalRead(pending, completion, asynchronous_reply);
      }
    } else if (pending.write) {
      status(pending.metadata, ClipboardStatus::done, pending.ending, asynchronous_reply);
    } else if (!kittyRead(pending, completion, asynchronous_reply)) {
      status(pending.metadata, ClipboardStatus::too_large, pending.ending, asynchronous_reply);
    }

    builder.commit();
    pending_.reset();
  }

  void Clipboard::traditionalRead(const Pending& pending, const CompleteClipboardDesktop& completion, Reply<ConcurrentMemory>& reply) {
    reply.append("\x1b]52;");
    reply.append({&pending.selection, 1});
    reply.append(";");
    for (const auto& content : completion.contents) {
      if (textMime(content.mime)) {
        clipboardBase64(reply, content.data);
        break;
      }
    }

    reply.append("\x1b\\");
  }

  bool Clipboard::kittyRead(const Pending& pending, const CompleteClipboardDesktop& completion, Reply<ConcurrentMemory>& reply) {
    ds::Array<ClipboardContentView, 4> contents;
    std::size_t count = 0;
    std::size_t total = 0;

    for (std::size_t index = 0; index < pending.mime_count; ++index) {
      const auto mime = pending.mimes[index].view();

      for (const auto& content : completion.contents) {
        if (content.mime != mime && !(textMime(mime) && textMime(content.mime))) {
          continue;
        }

        if (content.data.size() > maximum_bytes - total) {
          return false;
        }

        contents.atMut(count++) = {.mime = mime, .data = content.data};
        total += content.data.size();
        break;
      }
    }

    clipboardReadSuccess(reply, ClipboardPacket{.primary = pending.metadata.primary, .id = pending.metadata.id.view(), .ending = pending.ending}, std::span{contents}.first(count), completion.available, pending.listing);
    return true;
  }

  void Clipboard::discard() noexcept { // NOLINT(bugprone-exception-escape): the empty Vec shares the old one's memory, so the move hands storage over without allocating
    if (pending_) {
      cancelPending();
    }

    pending_.reset();
    transaction_.reset();
    grants_.clear();
    decoded_ = ds::Vec<std::uint8_t, ConcurrentMemory>{decoded_.memory()};
    for (auto& reply : replies_.replies.viewMut()) {
      reply.discard();
    }

    replies_.count = 0;
    replies_.head = 0;
  }

  void Clipboard::expire(Clock::time_point now) {
    if (pending_ && now >= pending_->deadline) {
      cancelPending();
      finish(ClipboardStatus::denied);
    }
  }

  bool Clipboard::hasReply() const noexcept {
    return replies_.count != 0;
  }

  void Clipboard::reset() {
    if (pending_) {
      cancelPending();
      finish(ClipboardStatus::denied);
    }

    transaction_.reset();
    grants_.clear();
  }

  bool Clipboard::paste(ClipboardRoute route, bool primary, std::span<const std::string_view> available) {
    if (!live(route) || replies_.count != 0) {
      return false;
    }

    try {
      const auto password = ClipboardGrants::password();
      ReplyBuilder builder{replies_};
      auto& asynchronous_reply = builder.reply();

      clipboardReadSuccess(asynchronous_reply, ClipboardPacket{.primary = primary, .password = password.view()}, {}, available, true);
      grants_.grant(password.view(), route, false, true);
      builder.commit();
      return true;
    } catch (const std::bad_alloc&) {
      return false;
    }
  }

  auto Clipboard::cancellation() const noexcept -> ds::Option<Cancellation> {
    return cancellation_;
  }

  void Clipboard::cancelled() noexcept {
    cancellation_.reset();
  }

  ds::Option<ClipboardDesktopExecute> Clipboard::execution() const noexcept {
    if (pending_ && pending_->prepared && !pending_->committed) {
      return ClipboardDesktopExecute{pending_->ticket};
    }

    return ds::none;
  }

  void Clipboard::committed() noexcept {
    if (pending_) {
      pending_.getMut().committed = true;
    }
  }

  Clipboard::Pending::Pending(ConcurrentMemory& memory)
      : text(memory) {
    randomBytes(&nonce, sizeof(nonce));
    if (nonce == 0) {
      nonce = 1;
    }
  }

  std::size_t Clipboard::Pending::prepareViews() noexcept {
    for (std::size_t index = 0; index < mime_count; ++index) {
      mime_views.atMut(index) = mimes[index].view();
    }

    std::size_t contents = 0;

    if (transaction) {
      for (const auto& content : transaction->contents()) {
        content_views.atMut(contents++) = {.mime = content.mime, .data = content.data};
      }
    } else if (traditional && write) {
      content_views.atMut(contents++) = {.mime = "text/plain", .data = text};
    }

    return contents;
  }

  bool Clipboard::textMime(std::string_view mime) noexcept {
    return mime == "text/plain" || mime == "text/plain;charset=utf-8" || mime == "UTF8_STRING" || mime == "STRING" || mime == "TEXT";
  }

  bool Clipboard::live(ClipboardRoute route) const noexcept {
    return std::ranges::contains(routes_.view().first(route_count_), route);
  }

  template <base64::Padding Rule>
  bool Clipboard::decode(std::string_view encoded) {
    if (encoded.size() > maximum_encoded_bytes) {
      return false;
    }

    decoded_.resize(std::min(maximum_bytes, (encoded.size() / 4 * 3) + (encoded.size() % 4 * 3 / 4)));
    const auto size = base64::decode<Rule>(encoded, decoded_.viewMut());
    if (!size) {
      return false;
    }

    decoded_.resize(*size);
    return true;
  }

  void Clipboard::status(const ClipboardMetadata& metadata, ClipboardStatus status, Ending ending, Reply<ConcurrentMemory>& reply) {
    clipboardPacket(reply, ClipboardPacket{.operation = metadata.operation == ClipboardOperation::read ? ClipboardOperation::read : ClipboardOperation::write, .status = status, .id = metadata.id.view(), .ending = ending});
  }

  void Clipboard::abort(ClipboardStatus result, Ending ending, Reply<ConcurrentMemory>& reply) {
    status(transaction_->metadata, result, ending, reply);
    transaction_.reset();
  }

  void Clipboard::cancelPending() noexcept {
    if (pending_->announced) {
      cancellation_ = Cancellation{.route = pending_->route, .ticket = pending_->ticket};
    }
  }

  void Clipboard::finish(ClipboardStatus result) {
    if (!pending_->traditional) {
      ReplyBuilder builder{replies_};

      status(pending_->metadata, result, pending_->ending, builder.reply());
      builder.commit();
    }

    pending_.reset();
  }

  ds::Option<ClipboardRoute> Clipboard::authorizedRoute(ClipboardGrants& grants, const ClipboardMetadata& metadata, bool write, bool exempt) {
    if (!exempt && !metadata.name.view().empty()) {
      if (const auto granted = grants.use(metadata.password.view(), write)) {
        return granted;
      }
    }

    return ds::none;
  }

  void Clipboard::read(const ClipboardMetadata& metadata, std::string_view data, Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply) {
    if (!decode(data)) {
      return;
    }

    auto decoded = textView(decoded_.view());

    try {
      validateUtf8(decoded);
    } catch (const EncodingError&) {
      return;
    }

    if (policy.clipboard_read == Access::deny || !preferred_) {
      status(metadata, ClipboardStatus::denied, ending, reply);
      return;
    }

    if (pending_ || cancellation_ || replies_.count != 0) {
      status(metadata, ClipboardStatus::busy, ending, reply);
      return;
    }

    pending_ = ds::makeBox<Pending>(memory_, memory_);
    auto& request = pending_.getMut();

    request.metadata = metadata;
    request.ending = ending;
    while (const auto mime = ClipboardWrite::token(decoded)) {
      if (*mime == ".") {
        request.listing = true;
      } else if (request.mime_count < request.mimes.size() && mime->size() <= ClipboardMetadata::maximum_mime && !mime->contains('\0')) {
        request.mimes.atMut(request.mime_count++).assign(*mime);
      }
    }

    const auto granted = authorizedRoute(grants_, metadata, false, request.mime_count == 0);

    request.route = granted.valueOr(*preferred_);
    request.prompt = policy.clipboard_read == Access::ask && request.mime_count != 0 && !granted;
  }

  void Clipboard::commit(Ending ending, const Policy& policy, Reply<ConcurrentMemory>& reply) {
    const auto result = transaction_.getMut().commit();
    if (result != ClipboardStatus::ok) {
      abort(result, ending, reply);
      return;
    }

    if (policy.clipboard_write == Access::deny || !preferred_) {
      abort(ClipboardStatus::denied, ending, reply);
      return;
    }

    if (pending_ || cancellation_ || replies_.count != 0) {
      abort(ClipboardStatus::busy, ending, reply);
      return;
    }

    pending_ = ds::makeBox<Pending>(memory_, memory_);
    auto& request = pending_.getMut();

    request.metadata = transaction_.getMut().metadata;
    request.write = true;
    request.ending = ending;
    const auto granted = authorizedRoute(grants_, request.metadata, true, false);

    request.route = granted.valueOr(*preferred_);
    request.prompt = policy.clipboard_write == Access::ask && !granted;
    request.transaction = std::move(transaction_);
  }

  Clipboard::ReplyBuilder::ReplyBuilder(ReplyRing& ring)
      : ring_(ring),
        reply_(ring.replies.atMut((ring.head + ring.count) % ring.replies.size())) {
    if (ring.count == ring.replies.size()) {
      throw std::logic_error{"Clipboard completion capacity invariant failed"};
    }
  }

  Clipboard::ReplyBuilder::~ReplyBuilder() {
    if (!committed_) {
      reply_.clear();
    }
  }

  Reply<ConcurrentMemory>& Clipboard::ReplyBuilder::reply() noexcept {
    return reply_;
  }

  void Clipboard::ReplyBuilder::commit() {
    reply_.seal();
    ++ring_.count;
    committed_ = true;
  }

}
