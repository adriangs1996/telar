#pragma once

// Every protocol message. Each domain header owns its messages and their schemas, and its
// telar.wire.<domain> module is the only module that includes it; this umbrella stays for
// textual users and for telar.client.protocol.
#include "../protocol/agents.hpp"
#include "../protocol/clients.hpp"
#include "../protocol/clipboard.hpp"
#include "../protocol/content.hpp"
#include "../protocol/editor.hpp"
#include "../protocol/execution.hpp"
#include "../protocol/graphics.hpp"
#include "../protocol/history.hpp"
#include "../protocol/layout.hpp"
#include "../protocol/pane_io.hpp"
#include "../protocol/runtime.hpp"
#include "../protocol/worktrees.hpp"
