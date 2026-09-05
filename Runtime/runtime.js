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

const trackingParameters = new Set([
    "fbclid", "gclid", "dclid", "msclkid", "yclid", "ttclid", "twclid",
    "igshid", "li_fat_id", "mc_cid", "mc_eid", "mkt_tok", "vero_conv",
    "vero_id", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "_hsenc", "_hsmi"
]);

function isTrackingParameter(rawKey) {
    let key = rawKey.replace(/\+/g, " ");
    try { key = decodeURIComponent(key); } catch (_) {}
    key = key.toLowerCase();
    return key.startsWith("utm_") || trackingParameters.has(key);
}

function stripTrackingFromURL(value) {
    const question = value.indexOf("?");
    if (question < 0) return value;
    const hash = value.indexOf("#", question);
    const base = value.slice(0, question);
    const query = value.slice(question + 1, hash < 0 ? value.length : hash);
    const fragment = hash < 0 ? "" : value.slice(hash);
    const kept = query.split("&").filter(part => part && !isTrackingParameter(part.split("=", 1)[0]));
    return base + (kept.length ? "?" + kept.join("&") : "") + fragment;
}

function cleanTrackingURLs(text) {
    return text.replace(/https?:\/\/[^\s<>"']+/g, match => {
        // Keep common sentence/Markdown punctuation outside the URL.
        let url = match, suffix = "";
        while (/[),.;!?]$/.test(url)) {
            suffix = url.slice(-1) + suffix;
            url = url.slice(0, -1);
        }
        return stripTrackingFromURL(url) + suffix;
    });
}

function cleanCopiedText(text) {
    let result = text;
    // Some Aktuality/Živé pages append an attribution footer to copied text.
    // Restrict this rule to their own URL so legitimate prose is not removed.
    result = result.replace(
        /\n{2,}Čítajte viac:\s*https?:\/\/(?:www\.)?zive\.aktuality\.sk\/[^\s]+(?:\s*\n_*\s*)?$/iu,
        ""
    );
    result = cleanTrackingURLs(result);
    return result;
}

function systemEvent(input) {
    if (!input || typeof input.kind !== "string" || typeof input.payload !== "object") {
        throw new Error("Invalid system event");
    }
    const operations = [];
    switch (input.kind) {
    case "clipboard.text.changed": {
        const text = input.payload.text;
        if (typeof text !== "string") throw new Error("Invalid clipboard text");
        const cleaned = cleanCopiedText(text);
        if (cleaned !== text) operations.push({kind:"clipboard.replaceText", text:cleaned});
        break;
    }
    // These events are intentionally exposed now so future runtime releases can
    // make pure decisions about them without another host rebuild. No native
    // operation is performed unless it is in the host's explicit allowlist.
    case "host.started":
    case "workspace.application.activated":
    case "workspace.didWake":
    case "workspace.willSleep":
    case "display.configuration.changed":
        break;
    default:
        break;
    }
    return {operations};
}

function dispatch(method,input) {
    switch(method) {
    case "gitPlan": return gitPlan(input);
    case "syncMessage": return syncMessage(input);
    case "bspBranches": return bspBranches(input);
    case "systemEvent": return systemEvent(input);
    case "selfTest": {
        if (gitPlan({ahead:1,behind:1}).integration !== "rebase") throw new Error("Git plan test");
        if (gitPlan({ahead:0,behind:1}).integration !== "fastForward") throw new Error("Git plan test");
        const tracked = "https://example.com/a?id=7&utm_source=x&fbclid=y#part";
        if (cleanCopiedText(tracked) !== "https://example.com/a?id=7#part") throw new Error("Tracking cleanup test");
        const injected = "Martin Senčák riaditeľ\n\nČítajte viac: https://zive.aktuality.sk/clanok/SW87rQh/tieto-zariadenia/?utm_source=x\n___";
        if (cleanCopiedText(injected) !== "Martin Senčák riaditeľ") throw new Error("Copy footer cleanup test");
        return {ok:true};
    }
    default: throw new Error("Unknown runtime method");
    }
}
