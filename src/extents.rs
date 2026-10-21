//! Measured union of physical data extents. Never infer physical usage from st_blocks.
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs,
    os::unix::fs::MetadataExt,
    path::Path,
    time::{Duration, Instant},
};
use walkdir::WalkDir;

fn union_bytes(ranges: &mut [(i64, i64)]) -> i64 {
    ranges.sort_unstable();
    let mut total = 0;
    let mut end = 0;
    for &(a, b) in ranges.iter() {
        if b > end {
            total += b - a.max(end);
            end = b;
        }
    }
    total
}

#[cfg(target_os = "macos")]
fn file_extents(path: &Path, m: &fs::Metadata) -> Result<Vec<(i64, i64)>> {
    use std::os::macos::fs::MetadataExt as MacMetadataExt;
    use std::{
        fs::OpenOptions,
        os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    };
    #[repr(C, packed(4))]
    struct Log2Phys {
        flags: u32,
        bytes: i64,
        offset: i64,
    }
    if m.st_flags() & 0x20 != 0 {
        bail!("Compressed data requires a different measurement method");
    }
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let fd = f.as_raw_fd();
    let mut volume = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::fstatvfs(fd, volume.as_mut_ptr()) } != 0 {
        bail!("Filesystem block granularity unavailable");
    }
    let block = unsafe { volume.assume_init() }.f_frsize as i64;
    if !(512..=1048576).contains(&block) || !(block as u64).is_power_of_two() {
        bail!("Unsupported filesystem block granularity");
    }
    let mut pos = 0i64;
    let mut ranges = Vec::new();
    while pos < m.len() as i64 {
        let data = unsafe { libc::lseek(fd, pos, libc::SEEK_DATA) };
        if data < 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(libc::ENXIO) {
                break;
            }
            return Err(e.into());
        }
        let mut v = Log2Phys {
            flags: 0,
            bytes: m.len() as i64 - data,
            offset: data,
        };
        if unsafe { libc::fcntl(fd, 65, &mut v) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let (offset, bytes) = (v.offset, v.bytes);
        if offset < 0 || bytes <= 0 {
            bail!("Filesystem did not return a physical extent");
        }
        let end = offset.checked_add(bytes).context("Extent overflow")?;
        let physical_start = offset / block * block;
        let physical_end = end.checked_add(block - 1).context("Extent overflow")? / block * block;
        ranges.push((physical_start, physical_end));
        pos = data.checked_add(bytes).context("Extent overflow")?;
        if ranges.len() > 100000 {
            bail!("Per-file extent budget reached");
        }
    }
    // Refuse partial fork mappings or unsupported compression rather than claim a wrong number.
    if union_bytes(&mut ranges) != (m.blocks() * 512) as i64 {
        bail!("Mapped extents do not reconcile with file block metadata");
    }
    let after = f.metadata()?;
    if (
        after.dev(),
        after.ino(),
        after.len(),
        after.mtime(),
        after.mtime_nsec(),
        after.blocks(),
    ) != (
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.blocks(),
    ) {
        bail!("File changed during measurement");
    }
    Ok(ranges)
}
#[cfg(not(target_os = "macos"))]
fn file_extents(_: &Path, _: &fs::Metadata) -> Result<Vec<(i64, i64)>> {
    bail!("Physical extent measurement is not supported on this platform");
}

pub fn measure(path: &Path, excluded: &Path, max_files: usize) -> Result<Value> {
    let root = fs::canonicalize(path)?;
    let excluded = fs::canonicalize(excluded)?;
    let started = Instant::now();
    let mut ranges: HashMap<u64, Vec<(i64, i64)>> = HashMap::new();
    let mut seen = HashSet::new();
    let mut files = 0;
    let mut measured = 0;
    let mut reported = 0u64;
    let mut errors = Vec::new();
    let mut directories = Vec::new();
    for e in WalkDir::new(&root)
        .follow_links(false)
        .same_file_system(true)
        .into_iter()
        .filter_entry(|e| !e.path().starts_with(&excluded))
    {
        if started.elapsed() > Duration::from_secs(15) || files >= max_files.clamp(1, 100000) {
            errors.push("Measurement budget reached; narrow the selection".to_string());
            break;
        }
        let e = match e {
            Ok(e) => e,
            Err(_) => {
                errors.push("A path could not be enumerated".into());
                continue;
            }
        };
        let m = match fs::symlink_metadata(e.path()) {
            Ok(m) => m,
            Err(_) => {
                errors.push("Metadata unavailable".into());
                continue;
            }
        };
        if m.is_dir() {
            directories.push((e.path().to_path_buf(), m.mtime(), m.mtime_nsec()));
            continue;
        }
        if !m.is_file() {
            continue;
        }
        files += 1;
        if !seen.insert((m.dev(), m.ino())) {
            continue;
        }
        reported += m.blocks() * 512;
        match file_extents(e.path(), &m) {
            Ok(extents) => {
                measured += 1;
                ranges.entry(m.dev()).or_default().extend(extents);
            }
            Err(e) => errors.push(e.to_string()),
        }
    }
    for (p, t, n) in directories {
        if fs::symlink_metadata(p)
            .map(|m| (m.mtime(), m.mtime_nsec()))
            .ok()
            != Some((t, n))
        {
            errors.push("Directory changed during measurement".into());
        }
    }
    let unique: i64 = ranges.values_mut().map(|r| union_bytes(r)).sum();
    let complete = errors.is_empty();
    Ok(
        json!({"method":"physical_extent_union","complete":complete,"unique_data_bytes":if complete{Some(unique)}else{None},"observed_data_bytes":unique,"reported_file_blocks_bytes":reported,"shared_bytes_not_double_counted":if complete{Some(reported.saturating_sub(unique as u64))}else{None},"files_visited":files,"distinct_files_measured":measured,"duration_seconds":started.elapsed().as_secs_f64(),"errors":errors.iter().take(10).collect::<Vec<_>>(),"reclaimable_bytes":null,"scope":"Data extents referenced within this selection, shared extents counted once. Excludes filesystem metadata; snapshots and references outside the selection can retain these blocks. Not a deletion saving.","as_of":crate::now()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_and_diverged_extents_count_once() {
        let mut r = vec![
            (4096, 8192),
            (4096, 8192),
            (8192, 12288),
            (16384, 20480),
            (6144, 8192),
        ];
        assert_eq!(union_bytes(&mut r), 12288);
    }
}
