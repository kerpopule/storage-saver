#![cfg(target_os = "macos")]
use std::{
    fs,
    io::{Seek, SeekFrom, Write},
    process::Command,
};
use storage_atlas::extents::measure;
#[test]
fn real_apfs_clones_divergence_sparse_hardlinks_and_budget() {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("data");
    let state = t.path().join("state");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir(&state).unwrap();
    let a = root.join("a");
    let b = root.join("b");
    fs::write(&a, vec![37; 16 * 1024 * 1024]).unwrap();
    assert!(
        Command::new("/bin/cp")
            .args(["-c"])
            .arg(&a)
            .arg(&b)
            .status()
            .unwrap()
            .success()
    );
    let clone = measure(&root, &state, 100).unwrap();
    assert_eq!(clone["complete"], true, "{clone}");
    assert_eq!(clone["unique_data_bytes"], 16 * 1024 * 1024);
    assert_eq!(clone["shared_bytes_not_double_counted"], 16 * 1024 * 1024);
    let mut f = fs::OpenOptions::new().write(true).open(&b).unwrap();
    f.seek(SeekFrom::Start(0)).unwrap();
    f.write_all(&vec![63; 4096]).unwrap();
    f.sync_all().unwrap();
    let diverged = measure(&root, &state, 100).unwrap();
    assert_eq!(diverged["complete"], true, "{diverged}");
    let unique = diverged["unique_data_bytes"].as_u64().unwrap();
    assert!(
        unique > 16 * 1024 * 1024 && unique < 32 * 1024 * 1024,
        "{diverged}"
    );
    fs::hard_link(&a, root.join("hardlink")).unwrap();
    let sparse = fs::File::create(root.join("sparse")).unwrap();
    sparse.set_len(1024 * 1024 * 1024).unwrap();
    let again = measure(&root, &state, 100).unwrap();
    assert_eq!(again["complete"], true, "{again}");
    assert_eq!(again["unique_data_bytes"], unique);
    let limited = measure(&root, &state, 1).unwrap();
    assert_eq!(limited["complete"], false);
    assert!(limited["unique_data_bytes"].is_null());
    assert!(again["reclaimable_bytes"].is_null());
}
#[test]
fn odd_length_clone_and_sparse_tail_round_to_real_blocks() {
    use std::os::unix::fs::MetadataExt;
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("files");
    let state = t.path().join("state");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&state).unwrap();
    let a = root.join("odd");
    fs::write(&a, vec![29; 1024 * 1024 + 13]).unwrap();
    let blocks = fs::metadata(&a).unwrap().blocks() * 512;
    assert!(
        Command::new("/bin/cp")
            .arg("-c")
            .arg(&a)
            .arg(root.join("odd-clone"))
            .status()
            .unwrap()
            .success()
    );
    let d = measure(&root, &state, 100).unwrap();
    assert_eq!(d["complete"], true, "{d}");
    assert_eq!(d["unique_data_bytes"], blocks);
    assert_eq!(d["shared_bytes_not_double_counted"], blocks);
    let mut f = fs::File::create(root.join("sparse-tail")).unwrap();
    f.seek(SeekFrom::Start(8 * 1024 * 1024 + 17)).unwrap();
    f.write_all(b"x").unwrap();
    f.sync_all().unwrap();
    let d = measure(&root, &state, 100).unwrap();
    assert_eq!(d["complete"], true, "{d}");
    assert_eq!(
        d["unique_data_bytes"],
        blocks + fs::metadata(root.join("sparse-tail")).unwrap().blocks() * 512
    );
}
#[test]
fn old_index_block_sum_is_never_renamed_physical_or_clamped() {
    let v = storage_atlas::accounting(
        serde_json::json!({"allocated":2200000000000_i64,"child":{"allocated_bytes":2400000000000_i64}}),
    );
    assert!(v.get("allocated").is_none());
    assert!(v["physical_data_bytes"].is_null());
    assert_eq!(v["referenced_file_blocks_bytes"], 2200000000000_i64);
    assert!(v["child"]["physical_data_bytes"].is_null());
}
