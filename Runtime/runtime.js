"use strict";

// Pure functions only. No native objects, filesystem, network, eval bridge or
// process launcher is exposed. The host validates every returned operation.
function gitPlan(input) {
    if (!Number.isInteger(input.ahead) || !Number.isInteger(input.behind) ||
        input.ahead < 0 || input.behind < 0) throw new Error("Invalid Git counts");
    return { integration: input.behind > 0 ? (input.ahead > 0 ? "rebase" : "fastForward") : "none" };
}

function syncMessage(input) {
    return input.autoCommitted ? "Saved yabairc and synchronized with GitHub" : "Synchronized with GitHub";
}

function bspBranches(input) {
    const fail = code => { throw new Error(code); };
    const target = input.snapshots.find(w => w.id === input.target);
    const valid = w => w["has-ax-reference"] && w["is-visible"] &&
        !w["is-floating"] && !w["is-minimized"] && !w["is-hidden"];
    if (!target) fail("targetNotFound");
    if (!valid(target)) fail("targetNotTiled");
    const tolerance = input.tolerance;
    const eligible = input.snapshots.filter(w => valid(w) && w.space === target.space &&
        w.display === target.display && w.frame.w > 0 && w.frame.h > 0);
    const hasRelations = eligible.some(w => w["split-type"] !== "none" || w["split-child"] !== "none");
    const relevant = hasRelations ? eligible.filter(w => w["split-type"] !== "none" && w["split-child"] !== "none") : eligible;
    if (new Set(relevant.map(w => w.id)).size !== relevant.length) fail("hierarchyCouldNotBeResolved");
    const equal = (a,b) => ["x","y","w","h"].every(k => Math.abs(a[k]-b[k]) <= tolerance);
    const groups = [];
    relevant.sort((a,b) => a.id-b.id).forEach(w => {
        const group = groups.find(g => equal(g[0].frame,w.frame));
        if (group) group.push(w); else groups.push([w]);
    });
    const leaves = groups.map((g,i) => {
        const first = g[0];
        if (!g.every(w => w["split-type"] === first["split-type"] && w["split-child"] === first["split-child"])) fail("inconsistentLeafMetadata");
        const stack = g.map(w => w["stack-index"]).sort((a,b) => a-b);
        if (g.length === 1 ? stack[0] !== 0 : !stack.every((v,i) => v === i+1)) fail("inconsistentLeafMetadata");
        return {frame:first.frame, ids:g.map(w => w.id), axis:first["split-type"],
            child:first["split-child"], signature:"L["+i+"]", distortion:0};
    });
    if (!leaves.some(l => l.ids.includes(input.target))) fail("targetNotTiled");
    if (leaves.length <= 1) fail("noParentBranch");
    // Explicit resource bounds. The host worker also has a wall-clock limit.
    if (leaves.length > 64) fail("ambiguousHierarchy");
    const union = (a,b) => ({x:Math.min(a.x,b.x), y:Math.min(a.y,b.y),
        w:Math.max(a.x+a.w,b.x+b.w)-Math.min(a.x,b.x),
        h:Math.max(a.y+a.h,b.y+b.h)-Math.min(a.y,b.y)});
    const memo = new Map();
    let reachedLimit = false, work = 0;
    const build = indices => {
        if (++work > 100000) fail("ambiguousHierarchy");
        const key = indices.slice().sort((a,b) => a-b).join(",");
        if (memo.has(key)) return memo.get(key);
        if (indices.length === 1) return [leaves[indices[0]]];
        const result = [], signatures = new Set();
        for (const axis of ["vertical","horizontal"]) {
            const p = axis === "vertical" ? "x" : "y", q = p === "x" ? "y" : "x";
            const len = p === "x" ? "w" : "h", span = len === "w" ? "h" : "w";
            const sorted = indices.slice().sort((a,b) => leaves[a].frame[p]-leaves[b].frame[p] || leaves[a].frame[q]-leaves[b].frame[q]);
            const bounds = ids => ids.map(i => leaves[i].frame).reduce(union);
            for (let i=1;i<sorted.length;i++) {
                const left=sorted.slice(0,i), right=sorted.slice(i), a=bounds(left), b=bounds(right);
                if (!(a[p] < b[p]-tolerance && (Math.abs(a[q]-b[q]) <= tolerance || Math.abs(a[q]+a[span]-b[q]-b[span]) <= tolerance))) continue;
                const firsts=build(left), seconds=build(right);
                const matches=(n,child) => n.first || (n.axis === axis && n.child === child);
                for (const first of firsts.filter(n => matches(n,"first_child"))) {
                    for (const second of seconds.filter(n => matches(n,"second_child"))) {
                        if (++work > 100000) fail("ambiguousHierarchy");
                        const signature=axis+"("+first.signature+","+second.signature+")";
                        if (signatures.has(signature)) continue;
                        signatures.add(signature);
                        if (result.length >= input.candidateLimit) { reachedLimit=true; continue; }
                        const a=first.frame,b=second.frame;
                        const overlap=Math.max(0,Math.min(a[p]+a[len],b[p]+b[len])-Math.max(a[p],b[p]));
                        result.push({first,second,signature,frame:union(a,b),ids:first.ids.concat(second.ids),
                            distortion:first.distortion+second.distortion+overlap/Math.min(a[len],b[len])});
                    }
                }
            }
        }
        memo.set(key,result);
        return result;
    };
    const candidates=build(leaves.map((_,i) => i));
    if (reachedLimit) fail("ambiguousHierarchy");
    if (!candidates.length) fail("hierarchyCouldNotBeResolved");
    const path=n => !n.first ? [] : path(n.first.ids.includes(input.target) ? n.first : n.second).concat([{frame:n.frame,windowIDs:n.ids}]);
    const minimum=Math.min(...candidates.map(n => n.distortion));
    const paths=candidates.filter(n => Math.abs(n.distortion-minimum)<=0.001).map(path);
    const signature=p => JSON.stringify(p.map(n => n.windowIDs.slice().sort((a,b) => a-b)));
    if (!paths.every(p => signature(p) === signature(paths[0]))) fail("ambiguousHierarchy");
    return paths[0];
}

function dispatch(method,input) {
    switch(method) {
    case "gitPlan": return gitPlan(input);
    case "syncMessage": return syncMessage(input);
    case "bspBranches": return bspBranches(input);
    case "selfTest":
        if (gitPlan({ahead:1,behind:1}).integration !== "rebase") throw new Error("Git plan test");
        if (gitPlan({ahead:0,behind:1}).integration !== "fastForward") throw new Error("Git plan test");
        return {ok:true};
    default: throw new Error("Unknown runtime method");
    }
}
