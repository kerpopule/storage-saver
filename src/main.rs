mod watchdog;
use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};
use storage_atlas::{
    Config, capacity, duplicates, growth, init, list, now, plan, progress, summary,
};
use tiny_http::{Header, Response, Server};
#[derive(Parser)]
#[command(
    version,
    about = "Storage Saver: private storage intelligence for people and agents"
)]
struct Cli {
    #[arg(
        long,
        global = true,
        help = "Private index location; never put it in a source repository"
    )]
    data: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        help = "Filesystem root; default macOS Data volume or / on other Unix"
    )]
    root: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        help = "Emit structured JSON (errors also use JSON)"
    )]
    json: bool,
    #[command(subcommand)]
    command: Option<Command>,
}
#[derive(Subcommand)]
enum Command {
    /// Open the standalone Storage Saver desktop application.
    Open,
    /// Copyable harness invitation and read-only index connection instructions.
    Invite,
    /// Ask the running native app to perform a grant-scoped action. Token comes from STORAGE_SAVER_GRANT.
    Agent { request: String },
    /// Measure the union of physical data extents in a selection, not stat block sums.
    Measure {
        path: String,
        #[arg(long, default_value_t = 10000)]
        max_files: usize,
    },
    /// Build a new metadata index. Previous complete index remains usable.
    Scan,
    /// Storage totals, category breakdown, coverage and index freshness.
    Status,
    /// Current scan progress; no index required.
    Progress,
    /// Live filesystem capacity, without scanning.
    Capacity,
    /// Ranked directories (nested rows overlap; do not sum).
    Top {
        #[arg(long,default_value="dirs",value_parser=["dirs","files","candidates"])]
        kind: String,
        #[arg(long, default_value = "")]
        query: String,
        #[arg(long, default_value_t = 50)]
        limit: u32,
        #[arg(long, default_value_t = 0)]
        offset: u32,
    },
    /// Direct children of an indexed directory.
    Browse {
        path: String,
        #[arg(long, default_value_t = 100)]
        limit: u32,
        #[arg(long, default_value_t = 0)]
        offset: u32,
    },
    /// Case-insensitive path search; literal text, not a shell or SQL expression.
    Search {
        query: String,
        #[arg(long, default_value_t = 50)]
        limit: u32,
        #[arg(long, default_value_t = 0)]
        offset: u32,
    },
    /// Growth between retained directory snapshots.
    Growth,
    /// Same-size duplicate candidates. Never claimed to be content-verified.
    Duplicates,
    /// Produce a review-only reclaim dossier. Cannot execute deletion.
    Plan { path: String },
    /// Loopback dashboard and scheduled index refresh. Ctrl-C stops both.
    Serve {
        #[arg(long, default_value_t = 43127)]
        port: u16,
        #[arg(long,default_value_t=21600,value_parser=clap::value_parser!(u64).range(60..))]
        interval: u64,
        /// Use existing non-interactive sudo permission for scan-only child processes.
        #[arg(long)]
        elevated_scan: bool,
    },
}
fn defaults(cli: &Cli) -> Config {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    let data = cli.data.clone().unwrap_or_else(|| {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share"))
            .join("storage-atlas")
    });
    let root = cli.root.clone().unwrap_or_else(|| {
        if cfg!(target_os = "macos") {
            PathBuf::from("/System/Volumes/Data")
        } else {
            PathBuf::from("/")
        }
    });
    Config::new(data, root)
}
fn output(value: &Value, as_json: bool) {
    if as_json {
        println!("{}", serde_json::to_string(value).unwrap())
    } else {
        println!("{}", serde_json::to_string_pretty(value).unwrap())
    }
}
fn main() {
    unsafe {
        libc::umask(0o077);
    }
    let cli = Cli::parse();
    if let Err(e) = run(&cli) {
        if cli.json {
            eprintln!("{}", json!({"error":format!("{e:#}")}))
        } else {
            eprintln!("Error: {e:#}")
        }
        std::process::exit(1)
    }
}
fn run(cli: &Cli) -> Result<()> {
    let cfg = defaults(cli);
    let v = match cli.command.as_ref().unwrap_or(&Command::Open) {
        Command::Open => {
            let status = if cfg!(target_os = "macos") {
                let exe = std::env::current_exe()?;
                let bundle = exe
                    .ancestors()
                    .find(|p| p.extension().is_some_and(|e| e == "app"))
                    .map(std::path::Path::to_path_buf)
                    .unwrap_or_else(|| {
                        PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                            .join("Applications/Storage Saver.app")
                    });
                std::process::Command::new("/usr/bin/open")
                    .arg(bundle)
                    .status()?
            } else {
                std::process::Command::new("xdg-open")
                    .arg("http://127.0.0.1:43127")
                    .status()?
            };
            if !status.success() {
                bail!("Storage Saver could not be opened ({status})");
            }
            return Ok(());
        }
        Command::Scan => {
            // This watchdog can terminate only this dedicated scanner process.
            // Never run it inside the long-lived dashboard.
            let (tx, rx) = std::sync::mpsc::channel();
            let as_json = cli.json;
            let guard = thread::spawn(move || {
                watchdog::watch(rx, Duration::from_secs(120), || {
                    let message = "Scan stalled: no traversal progress for 120s (or finalization exceeded 30m). Previous complete index retained; check filesystem availability and macOS privacy consent.";
                    if as_json {
                        eprintln!("{}", json!({"error":message,"exit_code":124}));
                    } else {
                        eprintln!("{message}");
                    }
                    std::process::exit(124);
                });
            });
            let mut last = std::time::Instant::now();
            let result = storage_atlas::scan_observed(&cfg, |_, finalizing| {
                if finalizing || last.elapsed() >= Duration::from_secs(1) {
                    let _ = tx.send(watchdog::Pulse::Working(Duration::from_secs(
                        if finalizing { 1800 } else { 120 },
                    )));
                    last = std::time::Instant::now();
                }
            });
            let _ = tx.send(watchdog::Pulse::Finished);
            let _ = guard.join();
            serde_json::to_value(result?)?
        }
        Command::Invite => invite(&cfg)?,
        Command::Agent { request } => agent_request(&cfg, request)?,
        Command::Measure { path, max_files } => {
            let (tx, rx) = std::sync::mpsc::channel();
            let guard = thread::spawn(move || {
                if rx.recv_timeout(Duration::from_secs(20)).is_err() {
                    eprintln!(
                        "{}",
                        json!({"error":"Measurement timed out; narrow selection","complete":false})
                    );
                    std::process::exit(124);
                }
            });
            let result =
                storage_atlas::extents::measure(std::path::Path::new(path), &cfg.data, *max_files);
            let _ = tx.send(());
            let _ = guard.join();
            result?
        }
        Command::Status => summary(&cfg)?,
        Command::Progress => progress(&cfg),
        Command::Capacity => capacity(&cfg.root)?,
        Command::Top {
            kind,
            query,
            limit,
            offset,
        } => list(&cfg, kind, query, *limit, *offset)?,
        Command::Browse {
            path,
            limit,
            offset,
        } => list(&cfg, "browse", path, *limit, *offset)?,
        Command::Search {
            query,
            limit,
            offset,
        } => list(&cfg, "search", query, *limit, *offset)?,
        Command::Growth => growth(&cfg)?,
        Command::Duplicates => duplicates(&cfg)?,
        Command::Plan { path } => plan(&cfg, path)?,
        Command::Serve {
            port,
            interval,
            elevated_scan,
        } => return serve(cfg, *port, *interval, *elevated_scan),
    };
    output(&storage_atlas::accounting(v), cli.json);
    Ok(())
}
fn invite(cfg: &Config) -> Result<Value> {
    let exe = std::env::current_exe()?;
    let cli = format!(
        "{} --data {}",
        shell_quote(&exe.to_string_lossy()),
        shell_quote(&cfg.data.to_string_lossy())
    );
    Ok(
        json!({"schema_version":2,"product":"Storage Saver","access":"index_only","text":format!("You are helping me manage this Mac using Storage Saver. Run locally on this Mac or my separately authorized shell. Do not expose its index or filenames externally.\n\nCLI: {cli}\nRead: status --json; browse /absolute/indexed/path --json; top --kind dirs --json; search QUERY --json; plan /absolute/indexed/path --json; measure /absolute/indexed/path --json.\nNumbers named referenced_file_blocks_bytes are NOT physical disk usage. APFS clones can share blocks. Only complete physical_extent_union measurements report unique_data_bytes; unknown means unknown, never zero or proportional estimates. Volume capacity is live. Measurement is not predicted deletion savings.\n\nThe native app separately grants View or Edit access to selected folders, either Ordinary or Elevated, with expiry and revocation. A copied grant invitation supplies STORAGE_SAVER_GRANT; call agent '{{\"action\":\"list\",\"path\":\"/selected/folder\"}}' --json. Without a grant, the index is read-only and does not authorize file contents or changes. Keep tokens private.\n\nIdentify active usage and unique files before proposing retirement. Present exact source/destination paths and a preservation plan. For backups verify the copy before retirement; use allowed copy/move/write actions only within the user's explicit grant. Never delete originals based on counted allocation, bypass macOS consent, request unrestricted sudo, or claim a backup/cleanup complete without readback. The user must review scopes/actions and accept the app's risk warning.") }),
    )
}
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
fn agent_request(cfg: &Config, text: &str) -> Result<Value> {
    use std::{
        io::{Read, Write},
        os::unix::net::UnixStream,
    };
    let mut request: Value = serde_json::from_str(text)?;
    request["token"] = json!(
        std::env::var("STORAGE_SAVER_GRANT")
            .context("Set the private grant from the native app in STORAGE_SAVER_GRANT")?
    );
    let mut stream = UnixStream::connect(cfg.data.join("agent.sock"))
        .context("Open the standalone app and create an unexpired access grant")?;
    stream.set_read_timeout(Some(Duration::from_secs(120)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut body = serde_json::to_vec(&request)?;
    if body.len() > 65536 {
        bail!("Request exceeds limit");
    }
    body.push(b'\n');
    stream.write_all(&body)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut out = String::new();
    stream.take(131073).read_to_string(&mut out)?;
    if out.len() > 131072 {
        bail!("Response exceeds limit");
    }
    Ok(serde_json::from_str(&out)?)
}
fn decode(s: &str) -> Result<String> {
    let mut bytes = Vec::new();
    let mut it = s.bytes();
    while let Some(c) = it.next() {
        if c == b'%' {
            let a = it.next().context("Invalid percent encoding")?;
            let b = it.next().context("Invalid percent encoding")?;
            let text = [a, b];
            bytes.push(u8::from_str_radix(std::str::from_utf8(&text)?, 16)?)
        } else {
            bytes.push(if c == b'+' { b' ' } else { c })
        }
    }
    Ok(String::from_utf8(bytes)?)
}
fn route(cfg: &Config, url: &str) -> Result<Value> {
    let (path, query) = url.split_once('?').unwrap_or((url, ""));
    let mut q = HashMap::new();
    for part in query.split('&').filter(|x| !x.is_empty()) {
        let (k, v) = part.split_once('=').unwrap_or((part, ""));
        q.insert(decode(k)?, decode(v)?);
    }
    let text = q.get("q").map(String::as_str).unwrap_or("");
    let limit = q.get("limit").and_then(|s| s.parse().ok()).unwrap_or(60);
    let offset = q.get("offset").and_then(|s| s.parse().ok()).unwrap_or(0);
    match path {
        "/api/invite" => invite(cfg),
        "/api/measure" => {
            let canonical = std::fs::canonicalize(text)?;
            let canonical = canonical.to_string_lossy();
            let _ = plan(cfg, &canonical)?;
            let out = std::process::Command::new(std::env::current_exe()?)
                .arg("--data")
                .arg(&cfg.data)
                .arg("--json")
                .arg("measure")
                .arg(canonical.as_ref())
                .output()?;
            if !out.status.success() {
                bail!(
                    "Measurement could not complete; narrow the selection or resolve native access. No total inferred."
                );
            }
            Ok(serde_json::from_slice(&out.stdout)?)
        }
        "/api/status" => summary(cfg),
        "/api/capacity" => capacity(&cfg.root),
        "/api/progress" => Ok(progress(cfg)),
        "/api/list" => list(
            cfg,
            q.get("mode").map(String::as_str).unwrap_or("dirs"),
            text,
            limit,
            offset,
        ),
        "/api/growth" => growth(cfg),
        "/api/duplicates" => duplicates(cfg),
        "/api/plan" => plan(cfg, text),
        _ => bail!("Unknown endpoint"),
    }
}
fn run_scan(cfg: &Config, elevated: bool) -> Result<()> {
    // Always isolate scanning, even without sudo: the fail-stop watchdog must
    // never terminate the HTTP server or its readable previous index.
    let exe = std::env::current_exe()?;
    let mut child = if elevated {
        let mut cmd = std::process::Command::new("/usr/bin/sudo");
        cmd.arg("-n").arg(&exe);
        cmd
    } else {
        std::process::Command::new(&exe)
    };
    let status = child
        .arg("--data")
        .arg(&cfg.data)
        .arg("--root")
        .arg(&cfg.root)
        .arg("scan")
        .status()
        .context("Start isolated metadata scanner")?;
    if !status.success() {
        bail!(
            "Metadata scanner failed ({status}); previous complete index retained. Inspect local scan log, filesystem availability and Full Disk Access. No sudoers changes are made."
        );
    }
    Ok(())
}
fn serve(cfg: Config, port: u16, interval: u64, elevated: bool) -> Result<()> {
    if unsafe { libc::geteuid() } == 0 {
        bail!(
            "Refusing to run the HTTP dashboard as root. Use serve --elevated-scan with an unprivileged dashboard instead."
        );
    }
    init(&cfg)?;
    let server = Server::http(("127.0.0.1", port)).map_err(|e| anyhow::anyhow!("{e}"))?;
    let working = Arc::new(AtomicBool::new(false));
    let requested = Arc::new(AtomicBool::new(false));
    let c = cfg.clone();
    let w = working.clone();
    let req = requested.clone();
    thread::spawn(move || {
        let mut next = summary(&c)
            .ok()
            .and_then(|s| s["scan"]["completed"].as_i64())
            .map(|at| at + interval as i64)
            .unwrap_or_else(now);
        loop {
            if now() >= next || req.swap(false, Ordering::SeqCst) {
                w.store(true, Ordering::SeqCst);
                if let Err(e) = run_scan(&c, elevated) {
                    let msg = json!({"state":"error","at":now(),"error":format!("{e:#}")});
                    let _ = std::fs::write(c.data.join("progress.json"), msg.to_string());
                    eprintln!("Scan failed: {e:#}");
                }
                w.store(false, Ordering::SeqCst);
                next = now() + interval as i64;
            }
            thread::sleep(Duration::from_secs(1));
        }
    });
    eprintln!(
        "Storage Saver: http://127.0.0.1:{port} | refresh every {interval}s | local metadata only"
    );
    let active = Arc::new(AtomicUsize::new(0));
    for request in server.incoming_requests() {
        if active.fetch_add(1, Ordering::SeqCst) >= 8 {
            active.fetch_sub(1, Ordering::SeqCst);
            let _ = request.respond(
                Response::from_string("Too many concurrent requests").with_status_code(429),
            );
            continue;
        }
        let active = active.clone();
        let cfg = cfg.clone();
        let working = working.clone();
        let requested = requested.clone();
        thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::SeqCst);
                }
            }
            let _active = Active(active);
            let host = request
                .headers()
                .iter()
                .find(|h| h.field.equiv("Host"))
                .map(|h| h.value.as_str())
                .unwrap_or("");
            let origin = request
                .headers()
                .iter()
                .find(|h| h.field.equiv("Origin"))
                .map(|h| h.value.as_str());
            let allowed = format!("127.0.0.1:{port}");
            let local = format!("localhost:{port}");
            let allowed_origin = format!("http://{allowed}");
            let local_origin = format!("http://{local}");
            let safe = (host == allowed || host == local)
                && origin.is_none_or(|o| o == allowed_origin || o == local_origin);
            let (status, content, body) = if !safe {
                (
                    403,
                    "application/json",
                    json!({"error":"Local origin required"}).to_string(),
                )
            } else if request.method().as_str() == "POST" && request.url() == "/api/rescan" {
                let custom = request
                    .headers()
                    .iter()
                    .any(|h| h.field.equiv("X-Atlas-Action") && h.value.as_str() == "rescan");
                if !custom {
                    (
                        403,
                        "application/json",
                        json!({"error":"Explicit rescan header required"}).to_string(),
                    )
                } else if working.load(Ordering::SeqCst) {
                    (
                        409,
                        "application/json",
                        json!({"error":"A scan is already running"}).to_string(),
                    )
                } else {
                    requested.store(true, Ordering::SeqCst);
                    (202, "application/json", json!({"queued":true}).to_string())
                }
            } else if request.method().as_str() != "GET" {
                (
                    405,
                    "application/json",
                    json!({"error":"Method not allowed"}).to_string(),
                )
            } else if request.url() == "/" {
                (
                    200,
                    "text/html; charset=utf-8",
                    include_str!("../web/index.html").into(),
                )
            } else if request.url() == "/app.js" {
                (
                    200,
                    "text/javascript; charset=utf-8",
                    include_str!("../web/app.js").into(),
                )
            } else if request.url() == "/style.css" {
                (
                    200,
                    "text/css; charset=utf-8",
                    include_str!("../web/style.css").into(),
                )
            } else {
                match route(&cfg, request.url()) {
                    Ok(v) => (
                        200,
                        "application/json",
                        storage_atlas::accounting(v).to_string(),
                    ),
                    Err(e) => (
                        if cfg.data.join("index.sqlite").exists() {
                            400
                        } else {
                            503
                        },
                        "application/json",
                        json!({"error":format!("{e:#}")}).to_string(),
                    ),
                }
            };
            let headers = [
                ("Content-Type", content),
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
                ("Referrer-Policy", "no-referrer"),
                (
                    "Content-Security-Policy",
                    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
                ),
            ];
            let mut response = Response::from_string(body).with_status_code(status);
            for (k, v) in headers {
                response.add_header(Header::from_bytes(k, v).unwrap())
            }
            let _ = request.respond(response);
        });
    }
    Ok(())
}
