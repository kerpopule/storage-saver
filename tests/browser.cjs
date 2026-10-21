/* Deterministic synthetic regression harness. No real account, browser profile or disk index. */
"use strict";
const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  cp = require("node:child_process");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const base = path.resolve(__dirname, "..");
const local = path.join(base, ".local", "browser-" + Date.now());
fs.mkdirSync(local, { recursive: true });
const root = path.join(local, "fixture"),
  data = path.join(local, "index");
fs.mkdirSync(path.join(root, "Projects", "demo", "build"), { recursive: true });
fs.mkdirSync(path.join(root, "Projects", "demo", ".git"), { recursive: true });
const hostile =
  "<img src=x onerror=alert(1)>_a_very_long_unbroken_filename_with_100_chars_abcdefghijklmnopqrstuvwxyz0123456789.txt";
fs.writeFileSync(path.join(root, hostile), "synthetic only");
fs.writeFileSync(path.join(root, "Projects", "demo", "package.json"), "{}");
fs.writeFileSync(
  path.join(root, "Projects", "demo", "build", "demo-output.bin"),
  Buffer.alloc(105 * 1024 * 1024, 1),
);
fs.symlinkSync("/", "" + path.join(root, "not-followed"));
const sparse = fs.openSync(path.join(root, "sparse.bin"), "w");
fs.ftruncateSync(sparse, 4 * 1024 ** 3);
fs.closeSync(sparse);
const bin =
    process.env.STORAGE_ATLAS_BIN ||
    path.join(base, "target", "debug", "storage-atlas"),
  port = Number(process.env.STORAGE_ATLAS_TEST_PORT || 43128),
  url = `http://127.0.0.1:${port}`;
if (process.platform === "darwin") cp.execFileSync("/bin/cp", ["-c", path.join(root, "Projects", "demo", "build", "demo-output.bin"), path.join(root, "Projects", "demo", "build", "clone-output.bin")]);
const args = ["--data", data, "--root", root];
function cli(...cmd) {
  return JSON.parse(
    cp.execFileSync(bin, [...args, ...cmd, "--json"], { encoding: "utf8" }),
  );
}
let server, browser;
const receipt = { fixture: true, checks: [], screenshots: [], page_errors: [] };
const check = (name) => receipt.checks.push(name);
async function read(route, options) {
  const r = await fetch(url + route, options);
  return { status: r.status, headers: r.headers, body: await r.json() };
}
(async () => {
  try {
    const first = cli("scan");
    assert.equal(first.errors, 0);
    assert.equal(first.symlinks, 1);
    check("real Rust fixture scan");
    const second = cli("scan");
    assert.equal(second.files, first.files);
    check("repeat scan is stable");
    const fail = cp.spawnSync(
      bin,
      ["--data", data, "--root", path.join(root, "missing"), "scan", "--json"],
      { encoding: "utf8" },
    );
    assert.notEqual(fail.status, 0);
    assert.ok(JSON.parse(fail.stderr).error);
    assert.equal(cli("status").scan.files, first.files);
    check("failed root retains previous complete index");
    const plan = cli("plan", path.join(root, "Projects", "demo", "build"));
    assert.equal(plan.execution_supported, false);
    assert.equal(plan.approval_required, true);
    check("review-only dossier, no delete authority");
    server = cp.spawn(bin, [...args, "serve", "--interval", "60", "--port", String(port)], {
      stdio: [
        "ignore",
        fs.openSync(path.join(local, "server.log"), "w"),
        fs.openSync(path.join(local, "server-error.log"), "w"),
      ],
    });
    let ready = false;
    for (let i = 0; i < 150; i++) {
      try {
        const r = await read("/api/capacity");
        if (r.status === 200) {
          ready = true;
          break;
        }
      } catch {}
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.ok(ready, "owned service ready");
    const forbidden = await read("/api/status", {
      headers: { Origin: "https://attacker.example" },
    });
    assert.equal(forbidden.status, 403);
    check("foreign Origin rejected");
    const rebinding = await new Promise((resolve, reject) => {
      require("node:http")
        .get(
          url + "/api/status",
          { headers: { Host: "attacker.example" } },
          (r) => {
            r.resume();
            resolve({ status: r.statusCode });
          },
        )
        .on("error", reject);
    });
    assert.equal(rebinding.status, 403);
    check("foreign Host rejected");
    assert.equal((await read("/api/rescan", { method: "POST" })).status, 403);
    check("rescan requires explicit header");
    assert.equal((await read("/api/delete", { method: "DELETE" })).status, 405);
    check("filesystem mutation endpoint absent");
    const status = await read("/api/status");
    assert.match(
      status.headers.get("content-security-policy"),
      /default-src 'self'/,
    );
    assert.equal(status.headers.get("cache-control"), "no-store");
    check("CSP and private no-store headers");
    const cap = await read("/api/capacity");
    assert.ok(cap.body.total_bytes > 0 && cap.body.free_bytes >= 0);
    check("live statvfs capacity");
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
      reducedMotion: "reduce",
    });
    const page = await context.newPage();
    page.on("pageerror", (e) => receipt.page_errors.push(String(e)));
    page.on("dialog", async (d) => {
      receipt.page_errors.push("unexpected dialog: " + d.message());
      await d.dismiss();
    });
    await page.goto(url, { waitUntil: "networkidle" });
    await page.locator(".entry").first().waitFor();
    assert.equal(await page.title(), "Storage Saver");
    await page.screenshot({
      path: path.join(local, "desktop.png"),
      fullPage: true,
    });
    receipt.screenshots.push("desktop.png");
    check("desktop real rendered dashboard");
    assert.equal(await page.locator("#indexed").textContent(), "Not measured");
    assert.equal((await page.locator("#rows").textContent()).includes("TB"), false);
    check("unmeasured file-block sums never presented as physical usage");
    await page.locator("#invite-agent").click();
    await page.locator("#agent-invitation[open]").waitFor();
    assert.ok((await page.locator("#invitation-text").inputValue()).includes("STORAGE_SAVER_GRANT"));
    await page.locator("#close-invitation").click();
    await page.locator("#grant-elevated").click();
    assert.ok((await page.locator("#notice").textContent()).includes("standalone"));
    assert.equal((await read("/api/grant", {method:"POST"})).status,405);
    check("invitation copypasta and native-only permission gate");
    await page
      .getByRole("button", { name: "Explore storage", exact: true })
      .click();
    await page.locator(".entry").first().waitFor();
    await page.getByRole("button", { name: "Projects", exact: true }).click();
    await page.getByRole("button", { name: "demo", exact: true }).waitFor();
    check("directory drilldown");
    await page.locator("#root").click();
    await page.getByRole("searchbox").fill("<img");
    await page.locator("#rows .entry").first().waitFor();
    await page.waitForFunction(
      () =>
        document.querySelectorAll("#rows .entry").length === 1 &&
        document.querySelector("#rows").textContent.includes("<img"),
    );
    assert.equal(await page.locator("#rows img").count(), 0);
    check("literal search and hostile filename escaping");
    await page.locator(".entry-review").first().click();
    await page.locator("#copy-plan:not([disabled])").waitFor();
    assert.ok(
      await page
        .locator("#plan-content")
        .textContent()
        .then((s) => s.includes("Guaranteed recovery: unknown")),
    );
    await page.keyboard.press("Escape");
    assert.equal(await page.locator("dialog[open]").count(), 0);
    check("review modal and keyboard Escape");
    await page.getByRole("searchbox").fill("zz-no-such-file");
    await page.waitForFunction(() =>
      document.querySelector("#rows").textContent.includes("No paths match"),
    );
    check("empty search");
    await page
      .getByRole("button", { name: "Recovery desk", exact: true })
      .click();
    await page.getByRole("button", { name: "build", exact: true }).waitFor();
    await page.locator(".entry-review").first().click();
    await page.locator("#copy-plan:not([disabled])").waitFor();
    if (process.platform === "darwin") {
      const measured = await read(`/api/measure?q=${encodeURIComponent(path.join(root,"Projects","demo","build"))}`);
      assert.equal(measured.body.complete,true);
      assert.equal(measured.body.unique_data_bytes,105*1024*1024);
      assert.equal(measured.body.shared_bytes_not_double_counted,105*1024*1024);
      await page.getByRole("button",{name:"Measure physical data",exact:true}).click();
      await page.waitForFunction(()=>document.querySelector("#plan-content").textContent.includes("measured data blocks"));
      check("real APFS clone union through engine API and dossier button");
    }
    const download = page.waitForEvent("download");
    await page.locator("#download-plan").click();
    const saved = await download;
    assert.equal(saved.suggestedFilename(), "storage-saver-review.json");
    await saved.saveAs(path.join(local, "dossier.json"));
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(local, "dossier.json"), "utf8"))
        .execution_supported,
      false,
    );
    await page.locator("#close-dialog").click();
    check("reclaim candidate dossier download");
    await page
      .getByRole("button", { name: "Index & coverage", exact: true })
      .click();
    await page.getByRole("heading", { name: "What this map knows" }).waitFor();
    assert.ok(
      (await page.locator("#special").textContent()).includes("not a realtime"),
    );
    check("coverage and honest freshness");
    await page
      .getByRole("button", { name: "Duplicate leads", exact: true })
      .click();
    await page.getByRole("heading", { name: "Leads, not verdicts" }).waitFor();
    check("duplicate uncertainty");
    await page
      .getByRole("button", { name: "What's growing", exact: true })
      .click();
    await page.getByRole("heading", { name: "Directory growth" }).waitFor();
    check("growth baseline view");
    for (const width of [320, 390, 768, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      await page.getByRole("button", { name: "Overview", exact: true }).click();
      await page.locator(".entry").first().waitFor();
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth > innerWidth + 1,
      );
      assert.equal(overflow, false, `no overflow at ${width}`);
      await page.screenshot({
        path: path.join(local, `width-${width}.png`),
        fullPage: true,
      });
      receipt.screenshots.push(`width-${width}.png`);
    }
    check("320/390/768/1440 widths without horizontal overflow");
    await page.setViewportSize({ width: 720, height: 900 });
    await page.evaluate(
      () => (document.documentElement.style.fontSize = "30px"),
    );
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth > innerWidth + 1,
      ),
      false,
    );
    check("200 percent root text sizing");
    assert.equal(receipt.page_errors.length, 0);
    check("no JavaScript page errors");
    // Explicit refresh through the actual HTTP contract, then prove it completed.
    const before = cli("status").scan.completed;
    await new Promise((r) => setTimeout(r, 1100));
    const queued = await read("/api/rescan", {
      method: "POST",
      headers: { "X-Atlas-Action": "rescan", Origin: url },
    });
    assert.equal(queued.status, 202);
    let refreshed = false;
    for (let i = 0; i < 100; i++) {
      const s = await read("/api/status");
      if (s.body.scan.completed > before) {
        refreshed = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.ok(refreshed);
    check("manual scheduled refresh completes and readback changes");
    const scheduledBase = (await read("/api/status")).body.scan.completed;
    let scheduled = false;
    for (let i = 0; i < 80; i++) {
      await new Promise(r => setTimeout(r, 1000));
      const s = (await read("/api/status")).body;
      if (s.scan.completed > scheduledBase && s.progress.state === "idle") { scheduled = true; break; }
    }
    assert.ok(scheduled, "configured 60-second automatic refresh must really fire");
    check("automatic scheduled refresh observed with completed index readback");
    receipt.passed = true;
    console.log(JSON.stringify(receipt, null, 2));
  } finally {
    if (browser) await browser.close();
    if (server) {
      server.kill("SIGTERM");
      await new Promise((r) => {
        if (server.exitCode !== null) return r();
        server.once("exit", r);
        setTimeout(() => {
          if (server.exitCode === null) server.kill("SIGKILL");
          r();
        }, 3000).unref();
      });
    }
    fs.writeFileSync(
      path.join(local, "result.json"),
      JSON.stringify(receipt, null, 2),
    );
    console.log("Evidence: " + local);
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
