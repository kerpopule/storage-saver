use std::{
    ffi::OsString,
    fs,
    os::unix::{
        ffi::OsStringExt,
        fs::{MetadataExt, symlink},
    },
};
use storage_atlas::{Config, category, list, plan, scan, summary};
fn fixture() -> (tempfile::TempDir, Config) {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("root");
    fs::create_dir_all(&root).unwrap();
    let c = Config::new(root.join("index"), root);
    (t, c)
}
#[test]
fn scanner_excludes_its_own_index() {
    let (_t, c) = fixture();
    fs::write(c.root.join("a"), "hello").unwrap();
    scan(&c).unwrap();
    let s = summary(&c).unwrap();
    assert_eq!(s["scan"]["files"], 1);
    assert!(
        list(&c, "search", "index.sqlite", 10, 0).unwrap()["entries"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
#[test]
fn hardlinks_and_nested_rollups_are_not_double_counted() {
    let (_t, c) = fixture();
    fs::create_dir_all(c.root.join("a/b")).unwrap();
    let f = c.root.join("a/b/payload");
    fs::write(&f, vec![1u8; 16384]).unwrap();
    fs::hard_link(&f, c.root.join("alias")).unwrap();
    let s = scan(&c).unwrap();
    assert_eq!(s.files, 2);
    assert_eq!(s.hardlink_aliases, 1);
    assert_eq!(s.logical_bytes, 16384);
    assert_eq!(
        s.allocated_bytes,
        (fs::metadata(f).unwrap().blocks() * 512) as i64
    );
    let root = fs::canonicalize(&c.root).unwrap();
    let r = list(&c, "browse", root.to_str().unwrap(), 100, 0).unwrap();
    assert_eq!(
        r["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["allocated"].as_i64().unwrap())
            .sum::<i64>(),
        s.allocated_bytes
    );
}
#[test]
fn sparse_and_invalid_names_are_explicit() {
    let (_t, c) = fixture();
    let f = fs::File::create(c.root.join("sparse")).unwrap();
    f.set_len(1024 * 1024 * 1024).unwrap();
    let invalid = fs::write(c.root.join(OsString::from_vec(vec![0xff, 0xfe])), "x");
    let s = scan(&c).unwrap();
    assert_eq!(s.logical_bytes, 1024 * 1024 * 1024);
    assert!(s.allocated_bytes < s.logical_bytes);
    assert_eq!(s.errors, if invalid.is_ok() { 1 } else { 0 });
}
#[test]
fn plans_have_no_execution_authority_and_detect_replacements() {
    let (_t, c) = fixture();
    let p = c.root.join("build");
    fs::create_dir(&p).unwrap();
    fs::write(p.join("asset"), "unique").unwrap();
    scan(&c).unwrap();
    let canonical = fs::canonicalize(&p).unwrap();
    let original = plan(&c, canonical.to_str().unwrap()).unwrap();
    assert_eq!(original["execution_supported"], false);
    assert_eq!(original["approval_required"], true);
    assert_eq!(
        original["guaranteed_reclaim_bytes"],
        serde_json::Value::Null
    );
    fs::rename(&p, c.root.join("retained")).unwrap();
    symlink(c.root.join("retained"), &p).unwrap();
    let changed = plan(&c, canonical.to_str().unwrap()).unwrap();
    assert_eq!(changed["indexed_metadata_matches"], false);
    assert!(c.root.join("retained/asset").exists());
}
#[test]
fn failed_root_keeps_previous_complete_index() {
    let (_t, c) = fixture();
    fs::write(c.root.join("a"), "x").unwrap();
    scan(&c).unwrap();
    let bad = Config::new(c.data.clone(), c.root.join("missing"));
    assert!(scan(&bad).is_err());
    assert_eq!(summary(&c).unwrap()["scan"]["files"], 1);
}
#[test]
fn protection_precedes_cache_and_build_classification() {
    for p in [
        "/home/person/.cache/huggingface/model.safetensors",
        "/home/person/project/build/.git/objects/pack",
        "/home/person/.ssh/id_ed25519",
    ] {
        assert_eq!(category(std::path::Path::new(p)).1, "protected");
    }
}
#[test]
fn pagination_is_exact_and_search_is_literal() {
    let (_t, c) = fixture();
    fs::write(c.root.join("file' OR 1=1 --"), "a").unwrap();
    scan(&c).unwrap();
    let root = fs::canonicalize(&c.root).unwrap();
    let r = list(&c, "browse", root.to_str().unwrap(), 1, 0).unwrap();
    assert_eq!(r["entries"].as_array().unwrap().len(), 1);
    assert_eq!(r["has_more"], false);
    let s = list(&c, "search", "' OR 1=1 --", 10, 0).unwrap();
    assert_eq!(s["entries"].as_array().unwrap().len(), 1);
}
