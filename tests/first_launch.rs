use storage_atlas::{Config, summary};

#[test]
fn fresh_catalog_is_a_first_launch_state_not_a_database_error() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("files");
    std::fs::create_dir(&root).unwrap();
    let cfg = Config::new(
        temp.path()
            .join("new account/Library/Application Support/StorageAtlas"),
        root,
    );
    let result = summary(&cfg).expect("A new Mac must not require a pre-existing SQLite catalog");
    assert_eq!(result["index_ready"], false);
    assert!(result["scan"].is_null());
    assert_eq!(result["state"], "awaiting_first_scan");
    assert_eq!(result["progress"]["state"], "not_started");
    assert!(result["capacity"]["total_bytes"].as_u64().unwrap() > 0);
    assert!(
        !cfg.data.join("index.sqlite").exists(),
        "Reading status must not manufacture an index"
    );
}

#[test]
fn damaged_catalog_is_not_misreported_as_first_launch() {
    let temp = tempfile::tempdir().unwrap();
    let cfg = Config::new(temp.path().join("state"), temp.path().to_path_buf());
    std::fs::create_dir(&cfg.data).unwrap();
    std::fs::write(cfg.data.join("index.sqlite"), b"not a database").unwrap();
    assert!(summary(&cfg).is_err());
}
