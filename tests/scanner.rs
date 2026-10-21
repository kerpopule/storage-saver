use std::{fs, os::unix::fs::symlink};
use storage_atlas::{Config, scan, summary};
#[test]
fn indexes_metadata_without_following_links() {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("root");
    fs::create_dir_all(root.join("nested")).unwrap();
    fs::write(root.join("nested/file"), vec![1u8; 8192]).unwrap();
    symlink("/", root.join("escape")).unwrap();
    let cfg = Config::new(t.path().join("index"), root.clone());
    scan(&cfg).unwrap();
    let s = summary(&cfg).unwrap();
    assert_eq!(s["scan"]["files"], 1);
    assert_eq!(s["scan"]["symlinks"], 1);
    assert_eq!(s["scan"]["logical_bytes"], 8192);
    assert_eq!(
        s["scan"]["root"],
        fs::canonicalize(root).unwrap().to_str().unwrap()
    );
}
