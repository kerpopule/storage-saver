//! Local metadata inventory and explicit, bounded physical-extent measurements.
pub mod extents;
use anyhow::{Context, Result, bail};
use fs2::FileExt;
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    ffi::CString,
    fs::{self, OpenOptions},
    os::fd::AsRawFd,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use walkdir::WalkDir;

#[derive(Clone, Debug)]
pub struct Config {
    pub data: PathBuf,
    pub root: PathBuf,
}
impl Config {
    pub fn new(data: PathBuf, root: PathBuf) -> Self {
        Self { data, root }
    }
}
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn sudo_owner(path: &Path) -> Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        return Ok(());
    }
    let (Ok(uid), Ok(gid)) = (std::env::var("SUDO_UID"), std::env::var("SUDO_GID")) else {
        return Ok(());
    };
    let uid: u32 = uid.parse()?;
    let gid: u32 = gid.parse()?;
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if unsafe { libc::fchown(f.as_raw_fd(), uid, gid) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
pub fn init(cfg: &Config) -> Result<()> {
    if cfg.data == Path::new("/") || cfg.data == cfg.root {
        bail!("Use a dedicated private state directory, not the scan root");
    }
    fs::create_dir_all(&cfg.data)?;
    sudo_owner(&cfg.data)?;
    fs::set_permissions(&cfg.data, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn atomic_json(path: &Path, value: &Value) -> Result<()> {
    let p = path.with_extension("tmp");
    fs::write(&p, serde_json::to_vec(value)?)?;
    sudo_owner(&p)?;
    fs::rename(p, path)?;
    Ok(())
}
#[derive(Default, Clone, Copy)]
struct Totals {
    logical: i64,
    allocated: i64,
    files: i64,
}
impl Totals {
    fn add(&mut self, o: Self) {
        self.logical += o.logical;
        self.allocated += o.allocated;
        self.files += o.files;
    }
}
#[derive(Serialize, Deserialize, Default)]
pub struct Scan {
    pub root: String,
    pub privileged: bool,
    pub started: i64,
    pub completed: i64,
    pub duration_seconds: f64,
    pub files: i64,
    pub directories: i64,
    pub symlinks: i64,
    pub hardlink_aliases: i64,
    pub logical_bytes: i64,
    #[serde(rename = "referenced_file_blocks_bytes", alias = "allocated_bytes")]
    pub allocated_bytes: i64,
    pub errors: i64,
    pub error_examples: Vec<String>,
    pub excluded: Vec<String>,
    pub categories: Vec<Value>,
}
fn alias(p: &Path) -> &Path {
    let b = p.as_os_str().as_bytes();
    let prefix = b"/System/Volumes/Data";
    if b.starts_with(prefix) && b.get(prefix.len()) == Some(&b'/') {
        Path::new(std::ffi::OsStr::from_bytes(&b[prefix.len()..]))
    } else {
        p
    }
}
pub fn category(path: &Path) -> (&'static str, &'static str, &'static str) {
    let s = path.to_string_lossy();
    let parts: Vec<_> = path
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect();
    let ext = path
        .extension()
        .and_then(|x| x.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if parts
        .iter()
        .any(|x| x == ".git" || x == ".ssh" || x == ".gnupg" || x == "Keychains")
        || path.file_name().is_some_and(|n| n == ".env")
    {
        return (
            "Protected",
            "protected",
            "Identity, secrets or version history. Never auto-clean.",
        );
    }
    if ["safetensors", "gguf", "ggml", "ckpt", "pt", "pth", "exl3"].contains(&ext.as_str())
        || parts
            .iter()
            .any(|x| x == "models" || x == "weights" || x == "huggingface" || x == "ollama")
    {
        return (
            "AI models",
            "protected",
            "Model residency and service use must be checked; never auto-clean.",
        );
    }
    if parts
        .iter()
        .any(|x| x == "node_modules" || x == "venv" || x == ".venv")
    {
        return (
            "Dependencies",
            "review",
            "Check active services, lockfiles and restoration cost; use your dependency guard.",
        );
    }
    if parts.iter().any(|x| {
        ["DerivedData", "target", ".next", "dist", "build", ".build"].contains(&x.as_ref())
    }) {
        return (
            "Build outputs",
            "review",
            "May contain unique releases. Check owner, Git state and retained outputs first.",
        );
    }
    if parts.iter().any(|x| x == "Caches" || x == ".cache") {
        return (
            "Caches",
            "review",
            "Cache is a clue, not deletion approval. May contain active models or downloads.",
        );
    }
    if parts.iter().any(|x| x == "Backups" || x == "backups") {
        return (
            "Backups",
            "review",
            "Verify another restorable copy. APFS clones may free far less than counted allocation.",
        );
    }
    if [
        "mp4", "mov", "mkv", "wav", "mp3", "png", "jpg", "webp", "blend", "glb",
    ]
    .contains(&ext.as_str())
    {
        return (
            "Media & assets",
            "keep",
            "Potentially unique source or accepted output. Preserve unless explicitly retired.",
        );
    }
    if s.contains("/Library/") || s.contains("/System/") || s.contains("/private/") {
        return (
            "System & app data",
            "keep",
            "Managed by the operating system or an application.",
        );
    }
    (
        "Projects & other",
        "keep",
        "Unclassified is not disposable. Identify owner and purpose.",
    )
}

pub fn scan(cfg: &Config) -> Result<Scan> {
    scan_observed(cfg, |_, _| {})
}

/// Report traversal liveness, including empty directories, to a process-local supervisor.
/// `finalizing` grants a longer deadline for SQLite index construction.
pub fn scan_observed(cfg: &Config, mut observe: impl FnMut(&Path, bool)) -> Result<Scan> {
    observe(&cfg.root, false);
    init(cfg)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(cfg.data.join("scan.lock"))?;
    lock.try_lock_exclusive()
        .context("Another scan owns the index; no second scan started")?;
    sudo_owner(&cfg.data.join("scan.lock"))?;
    let root = fs::canonicalize(&cfg.root).context("Cannot open scan root")?;
    fs::read_dir(&root).context("Cannot enumerate scan root; previous index retained")?;
    if !root.is_dir() {
        bail!("Scan root must be a directory")
    }
    let cfg = &Config::new(fs::canonicalize(&cfg.data)?, root.clone());
    if cfg.data == root {
        bail!("Private index directory resolves to the scan root");
    }
    let staging = cfg.data.join("building.sqlite");
    let db = Connection::open(&staging)?;
    // A watchdog/error may stop the scan before publication. Keep even the
    // unfinished catalog owned by the caller so an ordinary retry can replace it.
    sudo_owner(&staging)?;
    db.execute_batch("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32768; DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS meta; CREATE TABLE entries(path TEXT PRIMARY KEY,parent TEXT,name TEXT,kind TEXT,logical INTEGER,allocated INTEGER,files INTEGER,mtime INTEGER,dev INTEGER,inode INTEGER,nlink INTEGER,category TEXT,risk TEXT); CREATE TABLE meta(value TEXT); BEGIN;")?;
    let start = Instant::now();
    let mut last_progress = Instant::now();
    let mut info = Scan {
        root: root.to_string_lossy().into_owned(),
        privileged: unsafe { libc::geteuid() } == 0,
        started: now(),
        excluded: vec![
            cfg.data.display().to_string(),
            "Other filesystems / mounted volumes (scan each explicitly)".into(),
        ],
        ..Default::default()
    };
    let mut rollup: HashMap<PathBuf, Totals> = HashMap::new();
    let mut links = HashSet::new();
    let mut categories: HashMap<String, Totals> = HashMap::new();
    let mut count = 0i64;
    atomic_json(
        &cfg.data.join("progress.json"),
        &json!({"state":"scanning","pid":std::process::id(),"started":info.started,"entries":0,"files":0,"errors":0,"elapsed_seconds":0}),
    )?;
    let mut walk = WalkDir::new(&root)
        .follow_links(false)
        .same_file_system(true)
        .into_iter();
    let mut stack: Vec<PathBuf> = Vec::new();
    let mut stmt =
        db.prepare("INSERT INTO entries VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)")?;
    let insert_dir = |p: &Path, t: Totals, stmt: &mut rusqlite::Statement<'_>| -> Result<()> {
        let m = fs::symlink_metadata(p)?;
        let (cat, risk, _) = category(alias(p));
        stmt.execute(params![
            p.to_string_lossy(),
            p.parent()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default(),
            p.file_name().unwrap_or_default().to_string_lossy(),
            "directory",
            t.logical,
            t.allocated,
            t.files,
            m.mtime(),
            m.dev() as i64,
            m.ino() as i64,
            m.nlink() as i64,
            cat,
            risk
        ])?;
        Ok(())
    };
    while let Some(item) = walk.next() {
        let e = match item {
            Ok(e) => e,
            Err(e) => {
                info.errors += 1;
                if info.error_examples.len() < 40 {
                    info.error_examples.push(e.to_string())
                }
                continue;
            }
        };
        let p = e.path();
        observe(p, false);
        if alias(p).starts_with(alias(&cfg.data))
            || (root == Path::new("/System/Volumes/Data")
                && ["/System/Volumes/Data/Volumes", "/System/Volumes/Data/dev"]
                    .iter()
                    .any(|x| p == Path::new(x)))
        {
            if e.file_type().is_dir() {
                walk.skip_current_dir()
            }
            continue;
        }
        while stack.last().is_some_and(|d| !p.starts_with(d)) {
            let d = stack.pop().unwrap();
            let t = rollup.remove(&d).unwrap_or_default();
            if let Err(e) = insert_dir(&d, t, &mut stmt) {
                info.errors += 1;
                if info.error_examples.len() < 40 {
                    info.error_examples.push(e.to_string())
                }
            }
            if let Some(parent) = d.parent() {
                rollup.entry(parent.into()).or_default().add(t)
            }
        }
        let Some(text) = p.to_str() else {
            info.errors += 1;
            if info.error_examples.len() < 40 {
                info.error_examples
                    .push(format!("Non-UTF8 path omitted: {}", p.display()))
            }
            if e.file_type().is_dir() {
                walk.skip_current_dir()
            }
            continue;
        };
        let m = match fs::symlink_metadata(p) {
            Ok(m) => m,
            Err(err) => {
                info.errors += 1;
                if info.error_examples.len() < 40 {
                    info.error_examples.push(format!("{}: {err}", p.display()))
                }
                continue;
            }
        };
        if m.is_dir() {
            info.directories += 1;
            stack.push(p.into());
            continue;
        }
        let kind = if m.is_file() {
            "file"
        } else if m.file_type().is_symlink() {
            "symlink"
        } else {
            "special"
        };
        let mut t = Totals::default();
        if m.is_file() {
            info.files += 1;
            let unique = m.nlink() <= 1 || links.insert((m.dev() as i64, m.ino()));
            if unique {
                t = Totals {
                    logical: m.len() as i64,
                    allocated: (m.blocks() * 512) as i64,
                    files: 1,
                }
            } else {
                info.hardlink_aliases += 1;
            }
        }
        if kind == "symlink" {
            info.symlinks += 1
        }
        let (cat, risk, _) = category(alias(p));
        stmt.execute(params![
            text,
            p.parent().unwrap_or(&root).to_string_lossy(),
            p.file_name().unwrap_or_default().to_string_lossy(),
            kind,
            t.logical,
            t.allocated,
            t.files,
            m.mtime(),
            m.dev() as i64,
            m.ino() as i64,
            m.nlink() as i64,
            cat,
            risk
        ])?;
        if let Some(parent) = p.parent() {
            rollup.entry(parent.into()).or_default().add(t)
        }
        categories.entry(cat.to_string()).or_default().add(t);
        info.logical_bytes += t.logical;
        info.allocated_bytes += t.allocated;
        count += 1;
        if count % 20000 == 0 {
            db.execute_batch("COMMIT; BEGIN;")?;
        }
        if last_progress.elapsed().as_secs() >= 2 {
            atomic_json(
                &cfg.data.join("progress.json"),
                &json!({"state":"scanning","pid":std::process::id(),"started":info.started,"entries":count,"files":info.files,"errors":info.errors,"path":text,"elapsed_seconds":start.elapsed().as_secs()}),
            )?;
            last_progress = Instant::now();
        }
    }
    while let Some(d) = stack.pop() {
        let t = rollup.remove(&d).unwrap_or_default();
        if let Err(e) = insert_dir(&d, t, &mut stmt) {
            info.errors += 1;
            if info.error_examples.len() < 40 {
                info.error_examples.push(e.to_string())
            }
        }
        if let Some(parent) = d.parent() {
            rollup.entry(parent.into()).or_default().add(t)
        }
    }
    drop(stmt);
    info.categories = categories.into_iter().map(|(name,t)|json!({"name":name,"allocated":t.allocated,"logical":t.logical,"files":t.files})).collect();
    info.categories
        .sort_by_key(|x| std::cmp::Reverse(x["allocated"].as_i64().unwrap_or(0)));
    info.completed = now();
    info.duration_seconds = start.elapsed().as_secs_f64();
    db.execute(
        "INSERT INTO meta VALUES(?1)",
        [serde_json::to_string(&info)?],
    )?;
    observe(&root, true);
    db.execute_batch("COMMIT; CREATE INDEX entries_parent ON entries(parent); CREATE INDEX entries_size ON entries(kind,allocated DESC); CREATE INDEX entries_cat ON entries(kind,category); ANALYZE;")?;
    drop(db);
    sudo_owner(&staging)?;
    fs::rename(staging, cfg.data.join("index.sqlite"))?;
    record_history(cfg, &info)?;
    atomic_json(
        &cfg.data.join("progress.json"),
        &json!({"state":"idle","completed":info.completed,"entries":count,"errors":info.errors}),
    )?;
    Ok(info)
}
fn open(cfg: &Config) -> Result<Connection> {
    Connection::open_with_flags(
        cfg.data.join("index.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .context("No completed index yet. Run storage-atlas scan first.")
}
// libc block-count types differ: u32 on macOS, u64 on Linux.
#[allow(clippy::useless_conversion)]
pub fn capacity(root: &Path) -> Result<Value> {
    let c = CString::new(root.as_os_str().as_bytes())?;
    let mut s = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    let rc = unsafe { libc::statvfs(c.as_ptr(), s.as_mut_ptr()) };
    if rc != 0 {
        bail!("Capacity unavailable: {}", std::io::Error::last_os_error())
    }
    let s = unsafe { s.assume_init() };
    let unit = s.f_frsize;
    Ok(
        json!({"total_bytes":u64::from(s.f_blocks)*unit,"free_bytes":u64::from(s.f_bavail)*unit,"used_bytes":u64::from(s.f_blocks-s.f_bfree)*unit,"as_of":now()}),
    )
}
/// Legacy catalogs contain file-block sums, never verified physical usage.
/// Normalize them at the boundary without rewriting or rescaling the catalog.
pub fn accounting(mut value: Value) -> Value {
    match &mut value {
        Value::Object(map) => {
            for key in ["allocated", "allocated_bytes", "counted_allocated_bytes"] {
                if let Some(v) = map.remove(key) {
                    map.insert("referenced_file_blocks_bytes".into(), v);
                    map.insert("physical_data_bytes".into(), Value::Null);
                    map.insert("allocation_status".into(), json!("not_measured"));
                }
            }
            for v in map.values_mut() {
                *v = accounting(v.take());
            }
        }
        Value::Array(values) => {
            for v in values {
                *v = accounting(v.take());
            }
        }
        _ => {}
    }
    value
}

pub fn summary(cfg: &Config) -> Result<Value> {
    if matches!(
        fs::symlink_metadata(cfg.data.join("index.sqlite")),
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound
    ) {
        return Ok(json!({
            "index_ready": false,
            "state": "awaiting_first_scan",
            "scan": null,
            "capacity": capacity(&cfg.root)?,
            "categories": [],
            "index_storage": index_storage(cfg),
            "progress": progress(cfg),
            "notice": "Welcome to Storage Saver. Your first scan builds a private local map. No existing index is required."
        }));
    }
    let db = open(cfg)?;
    let scan: Value = serde_json::from_str(&db.query_row::<String, _, _>(
        "SELECT value FROM meta",
        [],
        |r| r.get(0),
    )?)?;
    let categories = scan["categories"].clone();
    Ok(
        json!({"scan":scan,"capacity":capacity(Path::new(scan["root"].as_str().unwrap_or("/")))?,"categories":categories,"index_storage":index_storage(cfg),"progress":progress(cfg),"notice":"Allocated blocks are not guaranteed reclaimable. APFS clones/shared extents, snapshots and concurrent changes affect real recovery. Metadata only; no file contents read."}),
    )
}
pub fn index_storage(cfg: &Config) -> Value {
    let mut files = Vec::new();
    let mut allocated = 0;
    let mut logical = 0;
    if let Ok(entries) = fs::read_dir(&cfg.data) {
        for entry in entries.flatten() {
            if let Ok(m) = fs::symlink_metadata(entry.path())
                && m.is_file()
            {
                allocated += m.blocks() * 512;
                logical += m.len();
                files.push(json!({"name":entry.file_name().to_string_lossy(),"logical":m.len(),"allocated":m.blocks()*512}));
            }
        }
    }
    json!({"logical":logical,"allocated":allocated,"files":files,"excluded_from_inventory":true,"notice":"Private index overhead. A scan builds a second catalog while keeping the previous one readable."})
}
pub fn progress(cfg: &Config) -> Value {
    let mut value: Value = fs::read(cfg.data.join("progress.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(json!({"state":"not_started"}));
    if value["state"] == "scanning"
        && let Some(pid) = value["pid"]
            .as_u64()
            .and_then(|n| i32::try_from(n).ok())
            .filter(|n| *n > 0)
    {
        // Signal 0 only checks whether the recorded scanner process exists.
        if unsafe { libc::kill(pid, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            value["state"] = json!("interrupted");
        }
    }
    value
}
fn rows<P, F>(db: &Connection, sql: &str, p: P, f: F) -> Result<Vec<Value>>
where
    P: rusqlite::Params,
    F: FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
{
    Ok(db
        .prepare(sql)?
        .query_map(p, f)?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}
fn entry(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(
        json!({"path":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"kind":r.get::<_,String>(2)?,"logical":r.get::<_,i64>(3)?,"allocated":r.get::<_,i64>(4)?,"files":r.get::<_,i64>(5)?,"mtime":r.get::<_,i64>(6)?,"category":r.get::<_,String>(7)?,"risk":r.get::<_,String>(8)?}),
    )
}
const FIELDS: &str = "path,name,kind,logical,allocated,files,mtime,category,risk";
fn catalog_path(db: &Connection, path: &str) -> String {
    let root = db
        .query_row::<String, _, _>("SELECT value FROM meta", [], |r| r.get(0))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v["root"].as_str().map(str::to_owned));
    if root
        .as_deref()
        .is_some_and(|r| r.starts_with("/System/Volumes/Data"))
        && path.starts_with('/')
        && !path.starts_with("/System/Volumes/Data")
    {
        format!("/System/Volumes/Data{path}")
    } else {
        path.to_owned()
    }
}
pub fn list(cfg: &Config, mode: &str, q: &str, limit: u32, offset: u32) -> Result<Value> {
    let db = open(cfg)?;
    let resolved = if mode == "browse" {
        catalog_path(&db, q)
    } else {
        q.to_owned()
    };
    let q = resolved.as_str();
    let limit = limit.clamp(1, 200);
    let (cond, arg) = match mode {
        "browse" => ("parent=?1", q),
        "files" => (
            "kind='file' AND allocated>0 AND (?1='' OR instr(path,?1)>0)",
            q,
        ),
        "search" => ("instr(lower(path),lower(?1))>0", q),
        "candidates" => (
            "kind='directory' AND risk='review' AND allocated>=104857600 AND (?1='' OR instr(path,?1)>0)",
            q,
        ),
        "dirs" => ("kind='directory' AND (?1='' OR instr(path,?1)>0)", q),
        _ => bail!("Unknown list mode"),
    };
    let sql = format!(
        "SELECT {FIELDS} FROM entries WHERE {cond} ORDER BY allocated DESC,path LIMIT ?2 OFFSET ?3"
    );
    let mut entries = rows(&db, &sql, params![arg, limit + 1, offset], entry)?;
    let has_more = entries.len() > limit as usize;
    entries.truncate(limit as usize);
    Ok(json!({"entries":entries,"limit":limit,"offset":offset,"has_more":has_more,"mode":mode}))
}
pub fn duplicates(cfg: &Config) -> Result<Value> {
    let db = open(cfg)?;
    let result = rows(
        &db,
        "SELECT logical,COUNT(*),SUM(allocated) FROM entries WHERE kind='file' AND logical>=10485760 AND files=1 AND risk!='protected' GROUP BY logical HAVING COUNT(*)>1 ORDER BY SUM(allocated) DESC LIMIT 40",
        [],
        |r| {
            Ok(
                json!({"logical_each":r.get::<_,i64>(0)?,"count":r.get::<_,i64>(1)?,"referenced_file_blocks_bytes":r.get::<_,i64>(2)?}),
            )
        },
    )?;
    let mut groups = Vec::new();
    for mut group in result {
        let bytes = group["logical_each"].as_i64().unwrap();
        group["examples"] = json!(rows(
            &db,
            "SELECT path FROM entries WHERE kind='file' AND logical=?1 AND files=1 AND risk!='protected' LIMIT 8",
            [bytes],
            |r| r.get::<_, String>(0).map(Value::String)
        )?);
        groups.push(group)
    }
    Ok(
        json!({"groups":groups,"verified":false,"notice":"Same-size candidates only, NOT verified duplicates. No reclaim estimate; content hashing is not performed."}),
    )
}
pub fn plan(cfg: &Config, path: &str) -> Result<Value> {
    let db = open(cfg)?;
    let resolved = catalog_path(&db, path);
    let path = resolved.as_str();
    let indexed = db.query_row(
        "SELECT dev,inode,mtime,allocated,kind,risk,logical FROM entries WHERE path=?1",
        [path],
        |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, String>(5)?,
                r.get::<_, i64>(6)?,
            ))
        },
    )?;
    let p = Path::new(path);
    let m = fs::symlink_metadata(p).context("Path no longer exists; refresh the index")?;
    let unchanged = m.dev() as i64 == indexed.0
        && m.ino() as i64 == indexed.1
        && m.mtime() == indexed.2
        && (indexed.4 != "file" || m.len() as i64 == indexed.6);
    let (cat, risk, reason) = category(alias(p));
    let owner = if m.is_dir() {
        p
    } else {
        p.parent().unwrap_or(p)
    }
    .ancestors()
    .take(64)
    .find(|a| fs::symlink_metadata(a.join(".git")).is_ok());
    let manifests: Vec<String> = if m.is_dir() {
        p
    } else {
        p.parent().unwrap_or(p)
    }
    .ancestors()
    .take(8)
    .flat_map(|a| {
        ["Cargo.toml", "package.json", "pyproject.toml", "go.mod"]
            .into_iter()
            .map(move |name| a.join(name))
    })
    .filter(|a| fs::symlink_metadata(a).is_ok())
    .map(|p| p.to_string_lossy().into_owned())
    .collect();
    Ok(
        json!({"schema_version":1,"path":path,"created":now(),"action":"review_only","execution_supported":false,"approval_required":true,"indexed_metadata_matches":unchanged,"descendants_revalidated":false,"category":cat,"risk":risk,"reason":reason,"ownership_clues":{"nearest_git_root":owner.map(|p|p.to_string_lossy()),"manifests":manifests,"live_usage_verified":false,"git_cleanliness_verified":false},"referenced_file_blocks_bytes":indexed.3,"physical_data_bytes":null,"guaranteed_reclaim_bytes":null,"identity":{"device":m.dev() as i64,"inode":m.ino() as i64,"mtime":m.mtime()},"checks":["Identify owner and active processes / services using this tree","Inspect Git tracked, untracked AND ignored contents; preserve unique outputs","Run dependency/model guards and check .keep-deps markers","Verify a restorable copy and explicit approval for the exact targets","Revalidate every descendant and symlink boundary immediately before any cleanup","Measure actual filesystem free bytes before and after; do not trust summed allocation"],"notice":"This plan grants no deletion authority and contains no executable delete command."}),
    )
}
fn record_history(cfg: &Config, info: &Scan) -> Result<()> {
    let db = open(cfg)?;
    let mut h = Connection::open(cfg.data.join("history.sqlite"))?;
    h.execute_batch("CREATE TABLE IF NOT EXISTS samples(at INTEGER,path TEXT,allocated INTEGER,PRIMARY KEY(at,path)); CREATE TABLE IF NOT EXISTS capacity(at INTEGER PRIMARY KEY,free INTEGER);")?;
    let tx = h.transaction()?;
    let mut stmt = tx.prepare("INSERT OR REPLACE INTO samples VALUES(?1,?2,?3)")?;
    for row in rows(
        &db,
        "SELECT path,allocated FROM entries WHERE kind='directory' AND allocated>=104857600 ORDER BY allocated DESC LIMIT 5000",
        [],
        |r| Ok(json!([r.get::<_, String>(0)?, r.get::<_, i64>(1)?])),
    )? {
        stmt.execute(params![
            info.completed,
            row[0].as_str().unwrap(),
            row[1].as_i64().unwrap()
        ])?;
    }
    drop(stmt);
    tx.execute(
        "INSERT OR REPLACE INTO capacity VALUES(?1,?2)",
        params![
            info.completed,
            capacity(Path::new(&info.root))?["free_bytes"]
                .as_i64()
                .unwrap()
        ],
    )?;
    tx.execute(
        "DELETE FROM samples WHERE at<?1",
        [now().saturating_sub(90 * 86400)],
    )?;
    tx.execute(
        "DELETE FROM capacity WHERE at<?1",
        [now().saturating_sub(90 * 86400)],
    )?;
    tx.commit()?;
    sudo_owner(&cfg.data.join("history.sqlite"))?;
    Ok(())
}
pub fn growth(cfg: &Config) -> Result<Value> {
    let h = Connection::open_with_flags(
        cfg.data.join("history.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let n: i64 = h.query_row("SELECT COUNT(DISTINCT at) FROM samples", [], |r| r.get(0))?;
    let v = if n < 2 {
        vec![]
    } else {
        rows(
            &h,
            "SELECT b.path,b.allocated-a.allocated,a.at,b.at FROM samples a JOIN samples b ON a.path=b.path WHERE a.at=(SELECT MIN(at) FROM samples) AND b.at=(SELECT MAX(at) FROM samples) ORDER BY b.allocated-a.allocated DESC LIMIT 60",
            [],
            |r| {
                Ok(
                    json!({"path":r.get::<_,String>(0)?,"delta":r.get::<_,i64>(1)?,"from":r.get::<_,i64>(2)?,"to":r.get::<_,i64>(3)?}),
                )
            },
        )?
    };
    Ok(
        json!({"snapshots":n,"entries":v,"notice":"Directory growth compares retained top-directory samples, not file event history. Requires two scans; nested rows overlap."}),
    )
}
