use std::{fs, path::Path};
use storage_atlas::{Config, scan_observed};

#[test]
fn progress_reports_directory_enumeration_and_finalization() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    fs::create_dir_all(root.join("empty/child")).unwrap();
    fs::write(root.join("file"), "fixture").unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let cfg = Config::new(temp.path().join("index"), root.clone());
    let mut observed = Vec::new();
    scan_observed(&cfg, |path, finalizing| {
        observed.push((path.to_path_buf(), finalizing))
    })
    .unwrap();
    assert!(
        observed
            .iter()
            .any(|(p, f)| p == &root.join("empty/child") && !f)
    );
    assert!(observed.iter().any(|(_, f)| *f));
    assert!(Path::new(&cfg.data.join("index.sqlite")).exists());
}

#[test]
fn symlinked_state_path_does_not_inventory_its_own_catalog() {
    use std::os::unix::fs::symlink;
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    fs::create_dir_all(root.join("state")).unwrap();
    fs::write(root.join("fixture"), "fixture").unwrap();
    let alias = temp.path().join("alias");
    symlink(&root, &alias).unwrap();
    let cfg = Config::new(alias.join("state"), root);
    let first = storage_atlas::scan(&cfg).unwrap();
    let second = storage_atlas::scan(&cfg).unwrap();
    assert_eq!(first.files, 1);
    assert_eq!(second.files, 1);
}
