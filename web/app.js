"use strict";
const $ = (s) => document.querySelector(s),
  el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };
const colors = [
  "#9ab977",
  "#354e43",
  "#c6b38a",
  "#7fa6a6",
  "#adc58e",
  "#8b9c88",
  "#d5b98d",
  "#b4b5a7",
  "#889d78",
];
let state = {
  view: "overview",
  root: "",
  path: "",
  mode: "browse",
  query: "",
  offset: 0,
  limit: 40,
  lastCompleted: 0,
  loaded: false,
  plan: null,
  request: 0,
};
const fmt = (n) => {
  if (!Number.isFinite(n)) return "—";
  if (n === 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB", "PB"];
  let i = Math.min(5, Math.floor(Math.log10(Math.abs(n)) / 3));
  return `${(n / 1000 ** i).toLocaleString(undefined, { maximumFractionDigits: i >= 3 ? 1 : 0 })} ${u[i]}`;
};
const short = (p) => p.replace(/^\/System\/Volumes\/Data(?=\/)/, "");
async function api(path, options) {
  const r = await fetch(path, options);
  const d = await r.json();
  if (!r.ok) throw Error(d.error || `Request failed (${r.status})`);
  return d;
}
function notice(text, error = false) {
  $("#notice").textContent = text;
  $("#notice").classList.toggle("error", error);
}
function capacity(d) {
  $("#free").textContent = fmt(d.free_bytes);
  $("#disk-caption").textContent =
    `${fmt(d.total_bytes - d.free_bytes)} unavailable of ${fmt(d.total_bytes)} total · live, not an index estimate`;
  $("#disk-used").style.width =
    `${Math.min(100, 100 * (1 - d.free_bytes / d.total_bytes))}%`;
  $("#used-label").textContent =
    `${(100 * (1 - d.free_bytes / d.total_bytes)).toFixed(1)}% unavailable`;
  $("#total-label").textContent = `${fmt(d.total_bytes)} total`;
}
function freshness(scan) {
  const seconds = Math.max(0, Date.now() / 1000 - scan.completed);
  $("#freshness").textContent =
    seconds < 60
      ? "Just now"
      : seconds < 3600
        ? `${Math.floor(seconds / 60)} min ago`
        : `${Math.floor(seconds / 3600)} hr ago`;
  $("#fresh-detail").textContent = new Date(
    scan.completed * 1000,
  ).toLocaleString();
  $("#footer-status").textContent =
    `Index: ${new Date(scan.completed * 1000).toLocaleString()} · ${scan.errors.toLocaleString()} coverage gaps`;
}
function firstLaunch(p = { state: "not_started" }) {
  state.progress = p;
  const scanning = p.state === "scanning";
  const failed = ["error", "interrupted"].includes(p.state);
  $("#rescan").disabled = scanning;
  $("#rescan").textContent = scanning ? "Scanning…" : failed ? "Retry first scan" : "Start first scan";
  if (state.view === "overview") {
    $("#heading").textContent = scanning ? "Building your first map" : "Welcome to Storage Saver";
    $("#subtitle").textContent = "Your private storage map is created on this Mac. No Terminal commands are needed.";
  }
  $("#file-count").textContent = scanning ? (p.files || 0).toLocaleString() : "—";
  $("#directory-count").textContent = scanning ? "Files discovered so far; the map appears after scanning finishes" : "No scan has completed on this Mac yet";
  $("#freshness").textContent = scanning ? "Scanning" : "Not scanned";
  $("#footer-status").textContent = scanning ? "First scan in progress · local metadata only" : "No completed index yet · your files have not been changed";
  const message = failed
    ? "Your first scan did not finish. Resolve any macOS access prompts, then choose Retry first scan. No completed map is available yet."
    : scanning
      ? "Your first scan is running. Live capacity is available now; your map appears automatically when it finishes."
      : "Start your first scan to map this Mac. Allow the macOS access prompts for folders you want included. Nothing is automatically deleted.";
  notice(message, failed);
  $("#rows").replaceChildren(el("div", "empty", message));
  $("#special").replaceChildren(el("p", "empty", message));
  $("#scan-progress").hidden = !scanning;
  if (scanning) $("#scan-progress").textContent = `Mapping storage · ${(p.files || 0).toLocaleString()} files · ${p.elapsed_seconds || 0}s elapsed`;
}
async function refresh() {
  try {
    const d = await api("/api/status");
    if (d.index_ready === false && d.scan === null) {
      capacity(d.capacity);
      firstLaunch(d.progress);
      return;
    }
    if (!state.loaded) {
      $("#heading").textContent = views[state.view][0];
      $("#subtitle").textContent = views[state.view][1];
      $("#rescan").textContent = "↻ Refresh index";
    }
    state.scan = d.scan;
    state.summary = d;
    state.root = d.scan.root;
    if (!state.path) state.path = state.root;
    state.loaded = true;
    capacity(d.capacity);
    freshness(d.scan);
    $("#indexed").textContent = "Not measured";
    $("#file-count").textContent = d.scan.files.toLocaleString();
    $("#directory-count").textContent =
      `${d.scan.directories.toLocaleString()} directories · ${d.scan.symlinks.toLocaleString()} symlink${d.scan.symlinks === 1 ? "" : "s"} not followed`;
    $("#categories").replaceChildren();
    $("#category-bar").replaceChildren();
    d.categories.forEach((c, i) => {
      const color = colors[i % colors.length];
      const segment = el("span");
      segment.style.background = color;
      segment.style.width = `${(100 * c.files) / Math.max(1, d.scan.files)}%`;
      segment.title = `${c.name}: ${c.files.toLocaleString()} files`;
      $("#category-bar").append(segment);
      const item = el("div", "category");
      const swatch = el("i");
      swatch.style.background = color;
      item.append(
        swatch,
        document.createTextNode(c.name),
        el("strong", "", `${c.files.toLocaleString()} ${c.files === 1 ? "file" : "files"}`),
      );
      $("#categories").append(item);
    });
    if (!state.lastCompleted) await render();
    state.lastCompleted = d.scan.completed;
    notice(
      d.scan.errors
        ? `${d.scan.errors.toLocaleString()} paths could not be fully read or indexed. Open Index & coverage for details. Nothing has been deleted.`
        : "",
    );
  } catch (e) {
    notice(`The local index could not be read: ${e.message}`, true);
    $("#rows").replaceChildren(
      el(
        "div",
        "empty",
        "The local index is unavailable. Retry the scan or resolve the reported access problem. Live capacity remains available.",
      ),
    );
  }
}
const views = {
  overview: [
    "A little room to breathe.",
    "See what takes space. Understand what matters. Reclaim with confidence.",
  ],
  explore: [
    "Follow the footprint.",
    "Move from the big picture to the exact directory or file.",
  ],
  recovery: [
    "Make room, thoughtfully.",
    "Review leads, not delete buttons. Protect the things you cannot replace.",
  ],
  growth: [
    "Catch the quiet growers.",
    "Compare indexed snapshots and see which folders changed.",
  ],
  duplicates: [
    "Same size. Second look.",
    "Potential duplicates, clearly separated from verified content matches.",
  ],
  coverage: [
    "Trust starts with coverage.",
    "Know exactly what was scanned, what was skipped, and when.",
  ],
};
function setView(view) {
  state.view = view;
  state.offset = 0;
  state.query = "";
  $("#search").value = "";
  document.querySelectorAll("nav button").forEach((b) => {
    b.classList.toggle("active", b.dataset.view === view);
    b.setAttribute("aria-current", b.dataset.view === view ? "page" : "false");
  });
  $("#heading").textContent = views[view][0];
  $("#subtitle").textContent = views[view][1];
  $("#overview").hidden = view !== "overview";
  $("#workspace").hidden = !["overview", "explore", "recovery"].includes(view);
  $("#special").hidden = ["overview", "explore", "recovery"].includes(view);
  render().catch((e) => notice(e.message, true));
}
function row(item, max) {
  const row = el("div", "entry");
  row.append(el("div", "entry-icon", item.kind === "directory" ? "▱" : "▤"));
  const main = el("div", "entry-main");
  const name = el("button", "entry-name", item.name || item.path);
  name.addEventListener("click", () =>
    item.kind === "directory" ? browse(item.path) : showPlan(item.path),
  );
  main.append(name, el("span", "path", short(item.path)));
  // No block-sum bar: APFS clones make those proportions misleading.
  row.append(main);
  const size = el("div", "entry-size", item.kind === "directory" ? `${item.files.toLocaleString()} files` : `${fmt(item.logical)} file bytes`);
  size.append(
    el(
      "small",
      "",
      `${item.category} · physical data not measured`,
    ),
  );
  row.append(size);
  const review = el("button", "entry-review", "Inspect");
  review.setAttribute("aria-label", `Inspect ${item.name || item.path}`);
  review.addEventListener("click", () => showPlan(item.path));
  row.append(review);
  return row;
}
async function browse(path) {
  state.path = path;
  state.mode = "browse";
  state.offset = 0;
  state.query = "";
  $("#search").value = "";
  $("#sort-mode").value = "browse";
  if (state.view === "overview") setView("explore");
  else await render();
}
async function render() {
  if (!state.loaded) return firstLaunch(state.progress);
  if (["growth", "duplicates", "coverage"].includes(state.view))
    return special();
  $("#toolbar").hidden = state.view === "recovery" || !!state.query;
  $("#list-title").textContent = state.query
    ? "Search results"
    : state.view === "recovery"
      ? "Worth a closer look"
      : "Where the space lives";
  $("#list-note").textContent =
    state.view === "recovery"
      ? "Build outputs, dependencies, caches and backups. Measure physical data before making a recovery plan."
      : "Browse file counts and content lengths. Use Inspect → Measure for shared-aware physical data.";
  $("#breadcrumb").textContent = short(state.path);
  $("#up").disabled = !state.path || state.path === state.root;
  $("#rows").replaceChildren(el("div", "empty", "Reading the index…"));
  const request = ++state.request;
  const mode = state.query
    ? "search"
    : state.view === "recovery"
      ? "candidates"
      : state.mode;
  const q = state.query || (mode === "browse" ? state.path : "");
  try {
    const d = await api(
      `/api/list?${new URLSearchParams({ mode, q, limit: state.limit, offset: state.offset })}`,
    );
    if (request !== state.request) return;
    $("#rows").replaceChildren();
    const max = 1;
    d.entries.forEach((e) => $("#rows").append(row(e, max)));
    if (!d.entries.length)
      $("#rows").append(
        el(
          "div",
          "empty",
          state.query
            ? "No paths match. Try a shorter part of the name."
            : "No entries in this view. A smaller footprint is a good thing.",
        ),
      );
    $("#prev").disabled = state.offset === 0;
    $("#next").disabled = !d.has_more;
    $("#page-label").textContent = d.entries.length
      ? `Showing ${state.offset + 1}–${state.offset + d.entries.length}`
      : "No entries";
  } catch (e) {
    if (request === state.request)
      $("#rows").replaceChildren(el("div", "empty", e.message));
  }
}
async function special() {
  const target = $("#special");
  target.replaceChildren(el("div", "empty", "Reading the index…"));
  const view = state.view;
  try {
    if (view === "coverage") {
      if (!state.scan)
        throw Error(
          "The initial scan has not completed. Progress appears above.",
        );
      target.replaceChildren(el("h2", "", "What this map knows"));
      const grid = el("div", "coverage-grid");
      const s = state.scan;
      for (const [title, body] of [
        ["Scope", s.root],
        ["Scanner privileges", s.privileged ? "Elevated metadata scanner. The dashboard remains unprivileged." : "Standard user. Elevated scan-only mode can cover ordinary UNIX permission gaps; Full Disk Access is separate."],
        [
          "Latest scan",
          `${new Date(s.started * 1000).toLocaleString()} → ${new Date(s.completed * 1000).toLocaleString()} · ${s.duration_seconds.toFixed(1)} seconds`,
        ],
        [
          "Coverage",
          `${s.files.toLocaleString()} files · ${s.directories.toLocaleString()} directories · ${s.errors.toLocaleString()} reported gaps`,
        ],
        [
          "Hardlinks & symlinks",
          `${s.hardlink_aliases.toLocaleString()} hardlink aliases not charged twice. ${s.symlinks.toLocaleString()} symlink${s.symlinks === 1 ? "" : "s"} not followed.`,
        ],
        [
          "Privacy",
          "The index reads metadata, not contents. Only a separately authorized native agent grant can read or modify selected files. No telemetry. Filenames and grant tokens are private.",
        ],
        [
          "Freshness",
          "Live capacity every 5 seconds. Full index refresh on the configured schedule (default: every 6 hours after a scan). This is not a realtime file-event index.",
        ],
        [
          "Not a filesystem snapshot",
          "Files can change during a scan. Allocated blocks can overlap on APFS. OS snapshots, directory metadata, protected paths and other volumes are not fully represented.",
        ],
        ["Excluded", s.excluded.join("\n")],
        ["Storage Saver’s own footprint", `${fmt(state.summary.index_storage?.referenced_file_blocks_bytes || 0)} file-block references in the private state folder, NOT unique physical usage; excluded from this map. Refreshes temporarily keep both the old and building catalog.`],
      ]) {
        const item = el("div", "coverage-item");
        item.append(el("strong", "", title), document.createTextNode(body));
        grid.append(item);
      }
      target.append(grid);
      if (s.errors) {
        target.append(
          el("h2", "", "Coverage gaps (first 40)"),
          el("pre", "", s.error_examples.join("\n")),
        );
      }
      return;
    }
    if (view === "growth") {
      const d = await api("/api/growth");
      if (state.view !== view) return;
      target.replaceChildren(
        el("h2", "", "Directory growth"),
        el("p", "subtitle", d.notice),
      );
      if (!d.entries.length) {
        target.append(
          el(
            "div",
            "empty",
            "Your baseline is saved. Growth appears after a second completed scan.",
          ),
        );
      } else
        for (const e of d.entries) {
          const item = el("div", "coverage-item");
          item.append(
            el("strong", "", `${e.delta >= 0 ? "+" : ""}${fmt(e.delta)} file-block change (not physical growth)`),
            el("div", "path", short(e.path)),
            el(
              "small",
              "",
              `${new Date(e.from * 1000).toLocaleString()} → ${new Date(e.to * 1000).toLocaleString()}`,
            ),
          );
          target.append(item);
        }
      return;
    }
    if (view === "duplicates") {
      const d = await api("/api/duplicates");
      if (state.view !== view) return;
      target.replaceChildren(
        el("h2", "", "Leads, not verdicts"),
        el("p", "subtitle", d.notice),
      );
      if (!d.groups.length)
        target.append(
          el(
            "div",
            "empty",
            "No same-size candidate groups above 10 MB in this index.",
          ),
        );
      for (const g of d.groups) {
        const item = el("div", "coverage-item");
        item.append(
          el(
            "strong",
            "",
            `${g.count.toLocaleString()} files · ${fmt(g.logical_each)} each`,
          ),
        );
        for (const p of g.examples) item.append(el("div", "path", short(p)));
        item.append(
          el("small", "", "Same-size only. Not a verified duplicate."),
        );
        target.append(item);
      }
    }
  } catch (e) {
    if (state.view === view)
      target.replaceChildren(el("div", "empty", e.message));
  }
}
async function showPlan(path) {
  const dialog = $("#dossier");
  $("#plan-path").textContent = short(path);
  $("#plan-content").replaceChildren(el("p", "", "Checking indexed metadata…"));
  $("#copy-plan").disabled = true;
  $("#download-plan").disabled = true;
  dialog.showModal();
  try {
    state.plan = await api(`/api/plan?q=${encodeURIComponent(path)}`);
    const p = state.plan;
    const warning = el(
      "div",
      "warning",
      `${p.category} · ${p.risk.toUpperCase()}\n${p.reason}`,
    );
    const meta = el(
      "p",
      "subtitle",
      `Physical data: not measured. Guaranteed recovery: unknown. ${p.indexed_metadata_matches ? "Top-level identity matches the index." : "Top-level metadata has changed; refresh before review."} Descendants have not been revalidated.`,
    );
    const owner = el(
      "p",
      "subtitle",
      p.ownership_clues?.nearest_git_root
        ? `Project clue: ${short(p.ownership_clues.nearest_git_root)}. Git cleanliness and live usage have not been verified.`
        : "Project ownership is not established. Live usage has not been verified.",
    );
    const checks = el("ol");
    p.checks.forEach((c) => checks.append(el("li", "", c)));
    const measure = el("button", "secondary", "Measure physical data");
    const measurement = el("p", "subtitle", "No physical-size estimate is inferred from the index. Measurement is bounded; large or inaccessible selections stay unmeasured.");
    measure.addEventListener("click", async () => {
      measure.disabled = true;
      measurement.textContent = "Measuring actual data extents, counting shared blocks once…";
      try {
        const result = await api(`/api/measure?q=${encodeURIComponent(path)}`);
        measurement.textContent = result.complete
          ? `${fmt(result.unique_data_bytes)} measured data blocks · ${fmt(result.shared_bytes_not_double_counted)} of repeated references excluded. ${result.scope}`
          : `Incomplete measurement. No physical total claimed. ${(result.errors || []).join("; ")}`;
      } catch (error) { measurement.textContent = `Not measured: ${error.message}`; }
      finally { measure.disabled = false; }
    });
    $("#plan-content").replaceChildren(
      warning,
      meta,
      measure,
      measurement,
      owner,
      checks,
      el("p", "subtitle", p.notice),
    );
    $("#copy-plan").disabled = false;
    $("#download-plan").disabled = false;
  } catch (e) {
    $("#plan-content").replaceChildren(el("p", "warning", e.message));
  }
}
function desktopAction(action) {
  if (window.webkit?.messageHandlers?.storageSaver) {
    window.webkit.messageHandlers.storageSaver.postMessage({ action });
    return true;
  }
  return false;
}
$("#invite-agent").addEventListener("click", async () => {
  if (desktopAction("invite")) return;
  try {
    const invitation = await api("/api/invite");
    $("#invitation-text").value = invitation.text;
    $("#agent-invitation").showModal();
  } catch (error) { notice(error.message, true); }
});
$("#close-invitation").addEventListener("click", () => $("#agent-invitation").close());
$("#copy-invitation").addEventListener("click", async () => {
  try { await navigator.clipboard.writeText($("#invitation-text").value); $("#copy-invitation").textContent = "Copied"; }
  catch (_) { $("#invitation-text").select(); notice("Clipboard unavailable. The instructions are selected for manual copy."); }
});
for (const [id, action] of [["#grant-ordinary", "grantOrdinary"], ["#grant-elevated", "grantElevated"], ["#manage-grants", "manageGrants"]]) {
  $(id).addEventListener("click", () => {
    if (!desktopAction(action)) notice("Open the standalone Storage Saver app to grant or revoke access. Browser pages cannot grant agent file permissions.", true);
  });
}
$("#close-dialog").addEventListener("click", () => $("#dossier").close());
$("#dossier").addEventListener("click", (e) => {
  if (e.target === $("#dossier")) {
    const r = e.target.getBoundingClientRect();
    if (
      e.clientX < r.left ||
      e.clientX > r.right ||
      e.clientY < r.top ||
      e.clientY > r.bottom
    )
      e.target.close();
  }
});
$("#copy-plan").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(JSON.stringify(state.plan, null, 2));
    $("#copy-plan").textContent = "Copied";
    setTimeout(() => ($("#copy-plan").textContent = "Copy JSON"), 1500);
  } catch (e) {
    notice(`Clipboard unavailable: ${e.message}. Use Save dossier.`, true);
  }
});
$("#download-plan").addEventListener("click", () => {
  const u = URL.createObjectURL(
    new Blob([JSON.stringify(state.plan, null, 2)], {
      type: "application/json",
    }),
  );
  const a = el("a");
  a.href = u;
  a.download = "storage-saver-review.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(u), 1000);
});
document
  .querySelectorAll("nav button")
  .forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));
$("#find-recovery").addEventListener("click", () => setView("recovery"));
$("#up").addEventListener("click", () =>
  browse(state.path.substring(0, state.path.lastIndexOf("/")) || "/"),
);
$("#root").addEventListener("click", () => browse(state.root));
$("#sort-mode").addEventListener("change", (e) => {
  state.mode = e.target.value;
  state.offset = 0;
  render();
});
$("#next").addEventListener("click", () => {
  state.offset += state.limit;
  render();
});
$("#prev").addEventListener("click", () => {
  state.offset = Math.max(0, state.offset - state.limit);
  render();
});
let searchTimer;
$("#search").addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value;
  searchTimer = setTimeout(() => {
    state.query = q;
    state.offset = 0;
    render();
  }, 250);
});
$("#rescan").addEventListener("click", async () => {
  try {
    await api("/api/rescan", {
      method: "POST",
      headers: { "X-Atlas-Action": "rescan" },
    });
    notice(
      state.loaded ? "Refresh queued. Your current index stays available while the next one builds." : "First scan queued. Your map will appear automatically when it finishes.",
    );
  } catch (e) {
    notice(e.message, true);
  }
});
let polling = false;
async function tick() {
  if (polling) return;
  polling = true;
  try {
    const [cap, p] = await Promise.all([
      api("/api/capacity"),
      api("/api/progress"),
    ]);
    capacity(cap);
    $("#scan-progress").hidden = p.state !== "scanning";
    if (p.state === "scanning")
      $("#scan-progress").textContent =
        `Mapping storage · ${(p.files || 0).toLocaleString()} files · ${p.elapsed_seconds || 0}s elapsed · ${(p.errors || 0).toLocaleString()} coverage gaps`;
    $("#rescan").disabled = p.state === "scanning";
    if (!state.loaded) firstLaunch(p);
    if (state.loaded && p.state === "error")
      notice(
        `Last refresh failed: ${p.error}. A previous complete index, if present, is retained.`,
        true,
      );
    if (p.state === "idle" && p.completed !== state.lastCompleted) {
      await refresh();
      if (state.loaded) await render();
    }
    if (state.scan) freshness(state.scan);
  } catch (e) {
    notice(`Local service unavailable: ${e.message}`, true);
  } finally {
    polling = false;
  }
}
refresh();
tick();
setInterval(tick, 5000);
