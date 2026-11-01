.pragma library

function measure(nodes, levels, gap) {
    const widths = {};
    const children = {};
    let width = 0;
    let roots = 0;
    let hidden = 0;
    for (const node of nodes) {
        const level = levels[node.index] ?? 0;
        widths[node.index] = level === 2 ? 0 : Math.max(0, node.width - (level === 1 ? node.compactDelta : 0));
    }
    for (let index = nodes.length - 1; index >= 0; --index) {
        const node = nodes[index];
        const size = widths[node.index];
        if (widths[node.parent] === undefined || (levels[node.index] ?? 0) === 2 || size <= 0) continue;
        const siblings = children[node.parent] ?? 0;
        widths[node.parent] += size + (siblings > 0 ? gap : 0);
        children[node.parent] = siblings + 1;
    }
    for (const node of nodes) {
        if (widths[node.parent] !== undefined) continue;
        if ((levels[node.index] ?? 0) === 2) {
            ++hidden;
        } else if (widths[node.index] > 0) {
            width += widths[node.index] + (roots > 0 ? gap : 0);
            ++roots;
        }
    }
    return {width: width, hidden: hidden};
}

function fit(nodes, available, gap, overflowWidth) {
    const levels = {};
    const children = {};
    for (const node of nodes) {
        if (node.parent >= 0) children[node.parent] = (children[node.parent] ?? 0) + 1;
    }
    // Each node can compact once and disappear once; groups wait for their children.
    for (let step = 0; step < 2 * nodes.length; ++step) {
        const size = measure(nodes, levels, gap);
        if (size.width + (size.hidden > 0 ? overflowWidth + gap : 0) <= available) break;
        let chosen = null;
        for (const node of nodes) {
            const level = levels[node.index] ?? 0;
            if (level === 2) continue;
            if (node.group ? (children[node.index] ?? 0) !== 0 : node.width - (level === 1 ? node.compactDelta : 0) <= 0) continue;
            if (chosen === null || node.priority <= chosen.priority) chosen = node;
        }
        if (chosen === null) break;
        const previous = levels[chosen.index] ?? 0;
        const next = chosen.meter && previous === 0 ? 1 : 2;
        levels[chosen.index] = next;
        if (next === 2 && chosen.parent >= 0) --children[chosen.parent];
    }
    return levels;
}
