//! Unicode box edge mappings adapted from Ghostty font/sprite/draw/box.zig.
// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
const Lines = @import("BoxLines.zig").Lines;

/// Returns the four edge weights. Dashes and curves use separate geometry.
/// Example: `const lines = box_lines.get(0x253c).?;`
pub fn get(codepoint: u21) ?Lines {
    return switch (codepoint) {
        0x2500 => .{ .left = .light, .right = .light },
        0x2501 => .{ .left = .heavy, .right = .heavy },
        0x2502 => .{ .up = .light, .down = .light },
        0x2503 => .{ .up = .heavy, .down = .heavy },
        0x250c => .{ .down = .light, .right = .light },
        0x250d => .{ .down = .light, .right = .heavy },
        0x250e => .{ .down = .heavy, .right = .light },
        0x250f => .{ .down = .heavy, .right = .heavy },
        0x2510 => .{ .down = .light, .left = .light },
        0x2511 => .{ .down = .light, .left = .heavy },
        0x2512 => .{ .down = .heavy, .left = .light },
        0x2513 => .{ .down = .heavy, .left = .heavy },
        0x2514 => .{ .up = .light, .right = .light },
        0x2515 => .{ .up = .light, .right = .heavy },
        0x2516 => .{ .up = .heavy, .right = .light },
        0x2517 => .{ .up = .heavy, .right = .heavy },
        0x2518 => .{ .up = .light, .left = .light },
        0x2519 => .{ .up = .light, .left = .heavy },
        0x251a => .{ .up = .heavy, .left = .light },
        0x251b => .{ .up = .heavy, .left = .heavy },
        0x251c => .{ .up = .light, .down = .light, .right = .light },
        0x251d => .{ .up = .light, .down = .light, .right = .heavy },
        0x251e => .{ .up = .heavy, .right = .light, .down = .light },
        0x251f => .{ .down = .heavy, .right = .light, .up = .light },
        0x2520 => .{ .up = .heavy, .down = .heavy, .right = .light },
        0x2521 => .{ .down = .light, .right = .heavy, .up = .heavy },
        0x2522 => .{ .up = .light, .right = .heavy, .down = .heavy },
        0x2523 => .{ .up = .heavy, .down = .heavy, .right = .heavy },
        0x2524 => .{ .up = .light, .down = .light, .left = .light },
        0x2525 => .{ .up = .light, .down = .light, .left = .heavy },
        0x2526 => .{ .up = .heavy, .left = .light, .down = .light },
        0x2527 => .{ .down = .heavy, .left = .light, .up = .light },
        0x2528 => .{ .up = .heavy, .down = .heavy, .left = .light },
        0x2529 => .{ .down = .light, .left = .heavy, .up = .heavy },
        0x252a => .{ .up = .light, .left = .heavy, .down = .heavy },
        0x252b => .{ .up = .heavy, .down = .heavy, .left = .heavy },
        0x252c => .{ .down = .light, .left = .light, .right = .light },
        0x252d => .{ .left = .heavy, .right = .light, .down = .light },
        0x252e => .{ .right = .heavy, .left = .light, .down = .light },
        0x252f => .{ .down = .light, .left = .heavy, .right = .heavy },
        0x2530 => .{ .down = .heavy, .left = .light, .right = .light },
        0x2531 => .{ .right = .light, .left = .heavy, .down = .heavy },
        0x2532 => .{ .left = .light, .right = .heavy, .down = .heavy },
        0x2533 => .{ .down = .heavy, .left = .heavy, .right = .heavy },
        0x2534 => .{ .up = .light, .left = .light, .right = .light },
        0x2535 => .{ .left = .heavy, .right = .light, .up = .light },
        0x2536 => .{ .right = .heavy, .left = .light, .up = .light },
        0x2537 => .{ .up = .light, .left = .heavy, .right = .heavy },
        0x2538 => .{ .up = .heavy, .left = .light, .right = .light },
        0x2539 => .{ .right = .light, .left = .heavy, .up = .heavy },
        0x253a => .{ .left = .light, .right = .heavy, .up = .heavy },
        0x253b => .{ .up = .heavy, .left = .heavy, .right = .heavy },
        0x253c => .{ .up = .light, .down = .light, .left = .light, .right = .light },
        0x253d => .{ .left = .heavy, .right = .light, .up = .light, .down = .light },
        0x253e => .{ .right = .heavy, .left = .light, .up = .light, .down = .light },
        0x253f => .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy },
        0x2540 => .{ .up = .heavy, .down = .light, .left = .light, .right = .light },
        0x2541 => .{ .down = .heavy, .up = .light, .left = .light, .right = .light },
        0x2542 => .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light },
        0x2543 => .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light },
        0x2544 => .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light },
        0x2545 => .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light },
        0x2546 => .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light },
        0x2547 => .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy },
        0x2548 => .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2549 => .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy },
        0x254a => .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy },
        0x254b => .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2550 => .{ .left = .double, .right = .double },
        0x2551 => .{ .up = .double, .down = .double },
        0x2552 => .{ .down = .light, .right = .double },
        0x2553 => .{ .down = .double, .right = .light },
        0x2554 => .{ .down = .double, .right = .double },
        0x2555 => .{ .down = .light, .left = .double },
        0x2556 => .{ .down = .double, .left = .light },
        0x2557 => .{ .down = .double, .left = .double },
        0x2558 => .{ .up = .light, .right = .double },
        0x2559 => .{ .up = .double, .right = .light },
        0x255a => .{ .up = .double, .right = .double },
        0x255b => .{ .up = .light, .left = .double },
        0x255c => .{ .up = .double, .left = .light },
        0x255d => .{ .up = .double, .left = .double },
        0x255e => .{ .up = .light, .down = .light, .right = .double },
        0x255f => .{ .up = .double, .down = .double, .right = .light },
        0x2560 => .{ .up = .double, .down = .double, .right = .double },
        0x2561 => .{ .up = .light, .down = .light, .left = .double },
        0x2562 => .{ .up = .double, .down = .double, .left = .light },
        0x2563 => .{ .up = .double, .down = .double, .left = .double },
        0x2564 => .{ .down = .light, .left = .double, .right = .double },
        0x2565 => .{ .down = .double, .left = .light, .right = .light },
        0x2566 => .{ .down = .double, .left = .double, .right = .double },
        0x2567 => .{ .up = .light, .left = .double, .right = .double },
        0x2568 => .{ .up = .double, .left = .light, .right = .light },
        0x2569 => .{ .up = .double, .left = .double, .right = .double },
        0x256a => .{ .up = .light, .down = .light, .left = .double, .right = .double },
        0x256b => .{ .up = .double, .down = .double, .left = .light, .right = .light },
        0x256c => .{ .up = .double, .down = .double, .left = .double, .right = .double },
        0x2574 => .{ .left = .light },
        0x2575 => .{ .up = .light },
        0x2576 => .{ .right = .light },
        0x2577 => .{ .down = .light },
        0x2578 => .{ .left = .heavy },
        0x2579 => .{ .up = .heavy },
        0x257a => .{ .right = .heavy },
        0x257b => .{ .down = .heavy },
        0x257c => .{ .left = .light, .right = .heavy },
        0x257d => .{ .up = .light, .down = .heavy },
        0x257e => .{ .left = .heavy, .right = .light },
        0x257f => .{ .up = .heavy, .down = .light },
        else => null,
    };
}
