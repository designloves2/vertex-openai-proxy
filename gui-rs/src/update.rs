//! Auto-update against this repo's GitHub releases (tags `windows-vX.Y[.Z]`).
//!
//! Uses only tools that ship with Windows 10/11 (`curl.exe`, `tar.exe`,
//! `robocopy`, `cmd`) so the exe needs no HTTP/TLS/zip crates.

use std::fs;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
pub const REPO: &str = "designloves2/vertex-openai-proxy";
const TAG_PREFIX: &str = "windows-v";
/// Files in the install folder an update must never overwrite.
pub const KEEP: [&str; 2] = [".env", ".gui-rs-settings"];

pub fn current_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[derive(Clone, Debug)]
pub struct Release {
    pub version: String,
    pub tag: String,
    pub zip_url: String,
}

fn parse_ver(s: &str) -> Vec<u64> {
    let mut v: Vec<u64> = s
        .trim_start_matches('v')
        .split(|c: char| c == '.' || c == '-')
        .map_while(|p| p.parse().ok())
        .collect();
    while v.len() < 3 {
        v.push(0);
    }
    v
}

pub fn is_newer(candidate: &str, current: &str) -> bool {
    parse_ver(candidate) > parse_ver(current)
}

/// Always the Windows-bundled tool (Git for Windows ships a GNU tar on PATH
/// that cannot read zips).
fn sys32(exe: &str) -> PathBuf {
    let base = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let p = base.join("System32").join(exe);
    if p.is_file() { p } else { PathBuf::from(exe) }
}

fn curl(args: &[&str]) -> Result<Vec<u8>, String> {
    let ua = format!("VertexOpenAIProxy-updater/{}", current_version());
    let out = Command::new(sys32("curl.exe"))
        .args(["-fsSL", "--max-time", "600", "-A", &ua])
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("could not run curl.exe: {}", e))?;
    if !out.status.success() {
        return Err(format!("curl failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(out.stdout)
}

/// Returns the newest non-draft, non-prerelease `windows-v*` release newer than
/// this exe, if any.
pub fn check() -> Result<Option<Release>, String> {
    let url = format!("https://api.github.com/repos/{}/releases?per_page=30", REPO);
    let body = curl(&["-H", "Accept: application/vnd.github+json", &url])?;
    let json: serde_json::Value = serde_json::from_slice(&body).map_err(|e| format!("bad JSON from GitHub: {}", e))?;
    let list = json.as_array().ok_or("unexpected GitHub response")?;
    let mut best: Option<Release> = None;
    for r in list {
        if r["draft"].as_bool().unwrap_or(false) || r["prerelease"].as_bool().unwrap_or(false) {
            continue;
        }
        let Some(tag) = r["tag_name"].as_str() else { continue };
        let Some(ver) = tag.strip_prefix(TAG_PREFIX) else { continue };
        let zip = r["assets"].as_array().and_then(|a| {
            a.iter()
                .filter_map(|x| x["browser_download_url"].as_str())
                .find(|u| u.to_ascii_lowercase().ends_with(".zip"))
        });
        let Some(zip) = zip else { continue };
        if !is_newer(ver, current_version()) {
            continue;
        }
        if best.as_ref().map_or(true, |b| is_newer(ver, &b.version)) {
            best = Some(Release { version: ver.to_string(), tag: tag.to_string(), zip_url: zip.to_string() });
        }
    }
    Ok(best)
}

fn find_payload(dir: &Path, depth: u32) -> Option<PathBuf> {
    if dir.join("index.js").is_file() && dir.join("VertexOpenAIProxy.exe").is_file() {
        return Some(dir.to_path_buf());
    }
    if depth == 0 {
        return None;
    }
    for e in fs::read_dir(dir).ok()?.flatten() {
        if e.path().is_dir() {
            if let Some(p) = find_payload(&e.path(), depth - 1) {
                return Some(p);
            }
        }
    }
    None
}

/// Downloads and extracts the release zip into a fresh temp folder; returns the
/// folder holding the new `VertexOpenAIProxy.exe` + `index.js`.
pub fn download(rel: &Release) -> Result<PathBuf, String> {
    let work = std::env::temp_dir().join(format!("VertexOpenAIProxy-update-{}", rel.version));
    let _ = fs::remove_dir_all(&work);
    let extract = work.join("x");
    fs::create_dir_all(&extract).map_err(|e| e.to_string())?;
    let zip = work.join("release.zip");
    curl(&["-o", &zip.to_string_lossy(), &rel.zip_url])?;
    let out = Command::new(sys32("tar.exe"))
        .arg("-xf")
        .arg(&zip)
        .arg("-C")
        .arg(&extract)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("could not run tar.exe: {}", e))?;
    if !out.status.success() {
        return Err(format!("unzip failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    find_payload(&extract, 2).ok_or_else(|| "release zip does not contain VertexOpenAIProxy.exe + index.js".into())
}

/// The install folder an update may replace: only when the running exe sits
/// directly in the project root (a release install), never a dev build under
/// `gui-rs\target`.
pub fn install_dir(root: &Path) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = exe.parent().ok_or("no exe folder")?;
    let same = fs::canonicalize(dir).ok() == fs::canonicalize(root).ok();
    if !same || !root.join("index.js").is_file() {
        return Err("this is not a release install (exe is not next to index.js); update it with git/build-release.ps1 instead".into());
    }
    Ok(root.to_path_buf())
}

/// Writes and launches a hidden helper that waits for this process to exit,
/// copies the new files over the install folder (keeping `.env` and
/// `.gui-rs-settings`), and restarts the exe. The caller must quit right after.
pub fn apply(payload: &Path, root: &Path) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let exe_name = exe.file_name().ok_or("no exe name")?.to_string_lossy().to_string();
    // Release exe is always VertexOpenAIProxy.exe; keep the installed name if it differs.
    if exe_name != "VertexOpenAIProxy.exe" {
        let _ = fs::rename(payload.join("VertexOpenAIProxy.exe"), payload.join(&exe_name));
    }
    let pid = std::process::id();
    let work = payload.parent().and_then(|p| p.parent()).unwrap_or(payload);
    let log = root.join("update.log");
    let script = work.join("apply-update.cmd");
    let keep = KEEP.join(" ");
    let body = format!(
        "@echo off\r\n\
         :wait\r\n\
         tasklist /FI \"PID eq {pid}\" /NH | find \" {pid} \" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)\r\n\
         set n=0\r\n\
         :copy\r\n\
         robocopy \"{src}\" \"{dst}\" /E /R:5 /W:1 /XF {keep} /NP /NDL > \"{log}\"\r\n\
         if not errorlevel 8 goto done\r\n\
         set /a n+=1\r\n\
         if %n% GEQ 5 goto done\r\n\
         ping -n 3 127.0.0.1 >nul\r\n\
         goto copy\r\n\
         :done\r\n\
         start \"\" \"{exe}\"\r\n",
        pid = pid,
        src = payload.display(),
        dst = root.display(),
        keep = keep,
        log = log.display(),
        exe = root.join(&exe_name).display(),
    );
    fs::write(&script, body).map_err(|e| format!("could not write update helper: {}", e))?;
    Command::new("cmd.exe")
        .arg("/c")
        .arg(&script)
        .current_dir(work)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("could not start update helper: {}", e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn versions() {
        assert!(is_newer("1.1", "1.0.0"));
        assert!(is_newer("1.0.1", "1.0"));
        assert!(!is_newer("1.0", "1.0.0"));
        assert!(!is_newer("1.0", "1.1.0"));
        assert!(is_newer("2.0", "1.9.9"));
    }
}
