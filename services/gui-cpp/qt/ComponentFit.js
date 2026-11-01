.pragma library

var Level = Object.freeze({full: 0, compact: 1, hidden: 2});
function measure(nodes, levels, gap) {
    const widths = {};
    const children = {};
    let width = 0;
    let roots = 0;
    let hidden = 0;
    for (const node of nodes) {
        const level = levels[node.index] ?? Level.full;
        widths[node.index] = level === Level.hidden ? 0 : Math.max(0, node.width - (level === Level.compact ? node.compactDelta : 0));
    }
    for (let index = nodes.length - 1; index >= 0; --index) {
        const node = nodes[index];
        const size = widths[node.index];
        if (widths[node.parent] === undefined || (levels[node.index] ?? Level.full) === Level.hidden || size <= 0) {
            continue;
        }
        const siblings = children[node.parent] ?? 0;
        widths[node.parent] += size + (siblings > 0 ? gap : 0);
        children[node.parent] = siblings + 1;
    }
    for (const node of nodes) {
        if (widths[node.parent] !== undefined) {
            continue;
        }
        if ((levels[node.index] ?? Level.full) === Level.hidden) {
            ++hidden;
        } else if (widths[node.index] > 0) {
            width += widths[node.index] + (roots > 0 ? gap : 0);
            ++roots;
        }
    }
    return {width: width, hidden: hidden};
}

function reduce(nodes, available, widthForLevels) {
    const levels = {};
    const children = {};
    for (const node of nodes) {
        if (node.parent >= 0) {
            children[node.parent] = (children[node.parent] ?? 0) + 1;
        }
    }
    // Each node can compact once and disappear once; groups wait for their children.
    const stepLimit = (Level.hidden - Level.full) * nodes.length;
    for (let step = 0; step < stepLimit; ++step) {
        if (widthForLevels(levels) <= available) {
            break;
        }
        let chosen = null;
        for (const node of nodes) {
            const level = levels[node.index] ?? Level.full;
            if (level === Level.hidden) {
                continue;
            }
            if (node.group ? (children[node.index] ?? 0) !== 0 : node.width - (level === Level.compact ? node.compactDelta : 0) <= 0) {
                continue;
            }
            if (chosen === null || node.priority <= chosen.priority) {
                chosen = node;
            }
        }
        if (chosen === null) {
            break;
        }
        const previous = levels[chosen.index] ?? Level.full;
        const next = chosen.meter && previous === Level.full ? Level.compact : Level.hidden;
        levels[chosen.index] = next;
        if (next === Level.hidden && chosen.parent >= 0) {
            --children[chosen.parent];
        }
    }
    return levels;
}

function fit(nodes, available, gap, overflowWidth) {
    return reduce(nodes, available, function(levels) {
        const size = measure(nodes, levels, gap);
        return size.width + (size.hidden > 0 ? overflowWidth + gap : 0);
    });
}

function rowWidth(widths, slots, gap) {
    let total = 0;
    let count = 0;
    for (let index = 0; index < widths.length; ++index) {
        if (widths[index] <= 0 && !slots[index].tabs) {
            continue;
        }
        total += widths[index] + (count > 0 ? gap : 0);
        ++count;
    }
    return total;
}

function slotWidths(slots, levels, layout) {
    return slots.map(function(slot) {
        if (slot.tabs) {
            return layout.tabMinimum;
        }
        if (slot.nodes.length === 0) {
            return slot.width * layout.fixedScale;
        }
        const size = measure(slot.nodes, levels, layout.gap);
        return size.width + (size.hidden > 0 ? slot.overflowWidth + (size.width > 0 ? layout.gap : 0) : 0);
    });
}

function allocate(slots, available, gap, minimumTabsWidth) {
    let stride = 1;
    let tabs = 0;
    let fixedWidth = 0;
    let active = 0;
    for (const slot of slots) {
        for (const node of slot.nodes) stride = Math.max(stride, node.index + 1);
        if (slot.tabs) {
            ++tabs;
        }
        else if (slot.nodes.length === 0) {
            fixedWidth += slot.width;
        }
        if (slot.tabs || slot.width > 0 || slot.nodes.length > 0) {
            ++active;
        }
    }
    const gaps = Math.max(0, active - 1) * gap;
    const tabMinimum = tabs > 0 ? Math.min(minimumTabsWidth, Math.max(0, available - gaps) / tabs) : 0;
    const fixedBudget = Math.max(0, available - gaps - tabMinimum * tabs);
    const layout = {gap: gap, tabMinimum: tabMinimum, fixedScale: fixedWidth > 0 ? Math.min(1, fixedBudget / fixedWidth) : 1};
    const sources = slots.map(function(slot, index) {
        return {tabs: slot.tabs, width: slot.width, overflowWidth: slot.overflowWidth, nodes: slot.nodes.map(function(node) {
            return {index: index * stride + node.index, parent: node.parent < 0 ? -1 : index * stride + node.parent,
                    group: node.group, meter: node.meter, width: node.width, priority: node.priority, compactDelta: node.compactDelta};
        })};
    });
    let nodes = [];
    for (const source of sources) nodes = nodes.concat(source.nodes);
    const levels = reduce(nodes, available, function(reduced) {
        return rowWidth(slotWidths(sources, reduced, layout), sources, gap);
    });
    const widths = slotWidths(sources, levels, layout);
    const used = rowWidth(widths, sources, gap);
    if (used > available) {
        let flexible = 0;
        for (let index = 0; index < sources.length; ++index) {
            if (sources[index].tabs || sources[index].nodes.length === 0) {
                flexible += widths[index];
            }
        }
        const retained = used - flexible;
        const scale = flexible > 0 ? Math.min(1, Math.max(0, available - retained) / flexible) : 1;
        for (let index = 0; index < sources.length; ++index) {
            if (sources[index].tabs || sources[index].nodes.length === 0) {
                widths[index] *= scale;
            }
        }
    }
    const spare = tabs > 0 ? Math.max(0, available - rowWidth(widths, sources, gap)) / tabs : 0;
    for (let index = 0; index < sources.length; ++index) {
        if (sources[index].tabs) {
            widths[index] += spare;
        }
    }
    const localLevels = slots.map(function(slot, index) {
        const local = {};
        for (const node of slot.nodes) {
            const level = levels[index * stride + node.index];
            if (level !== undefined) {
                local[node.index] = level;
            }
        }
        return local;
    });
    return {widths: widths, levels: localLevels};
}
