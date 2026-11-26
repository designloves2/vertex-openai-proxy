#![windows_subsystem = "windows"]
//! Vertex OpenAI Proxy control panel (Rust, native Win32, real system-tray icon).

mod update;

use native_windows_gui as nwg;
use std::cell::RefCell;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const ENV_KEYS: [&str; 4] = [
    "GOOGLE_CLOUD_PROJECT_ID",
    "GOOGLE_CLOUD_LOCATION",
    "GOOGLE_CLOUD_MODEL_ID",
    "PORT",
];
const FALLBACK_MODELS: [&str; 5] = [
    "gemini-3.7-flash",
    "gemini-3.1-pro-preview",
    "gemini-3.8-flash",
    "gemini-1.5-pro-002",
    "gemini-1.5-flash-002",
];
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

struct Paths {
    root: PathBuf,
    env: PathBuf,
    command: PathBuf,
    settings: PathBuf,
    out_log: PathBuf,
    err_log: PathBuf,
}

fn find_paths() -> Paths {
    let mut root = std::env::current_dir().unwrap_or_default();
    if let Ok(exe) = std::env::current_exe() {
        for a in exe.ancestors().skip(1) {
            if a.join("index.js").exists() {
                root = a.to_path_buf();
                break;
            }
        }
    }
    let tmp = std::env::temp_dir();
    Paths {
        env: root.join(".env"),
        command: root.join(".gui-command"),
        settings: root.join(".gui-rs-settings"),
        out_log: tmp.join("vertex-openai-proxy-out.log"),
        err_log: tmp.join("vertex-openai-proxy-err.log"),
        root,
    }
}

// ---- .env helpers (no BOM, only touch managed keys) ----
fn read_env(p: &Paths) -> [String; 4] {
    let mut v = [
        String::new(),
        "global".to_string(),
        "gemini-3.7-flash".to_string(),
        "3000".to_string(),
    ];
    if let Ok(text) = fs::read_to_string(&p.env) {
        for line in text.lines() {
            let t = line.trim().trim_start_matches('\u{feff}');
            if t.is_empty() || t.starts_with('#') {
                continue;
            }
            if let Some((k, val)) = t.split_once('=') {
                if let Some(i) = ENV_KEYS.iter().position(|x| *x == k.trim()) {
                    v[i] = val.trim().to_string();
                }
            }
        }
    }
    v
}

fn write_env(p: &Paths, v: &[String; 4]) -> std::io::Result<()> {
    let mut out: Vec<String> = Vec::new();
    let mut seen = [false; 4];
    if let Ok(text) = fs::read_to_string(&p.env) {
        for line in text.lines() {
            let t = line.trim_end().trim_start_matches('\u{feff}');
            let key = t.split_once('=').map(|(k, _)| k.trim().to_string());
            if let Some(i) = key.as_ref().and_then(|k| ENV_KEYS.iter().position(|x| x == k)) {
                if seen[i] {
                    continue;
                }
                seen[i] = true;
                out.push(format!("{}={}", ENV_KEYS[i], v[i]));
            } else {
                out.push(t.to_string());
            }
        }
    }
    for i in 0..4 {
        if !seen[i] {
            out.push(format!("{}={}", ENV_KEYS[i], v[i]));
        }
    }
    let mut body = out.join("\r\n");
    body.push_str("\r\n");
    fs::write(&p.env, body)
}

fn port_in_use(port: &str) -> bool {
    match format!("127.0.0.1:{}", port).parse::<SocketAddr>() {
        Ok(a) => TcpStream::connect_timeout(&a, Duration::from_millis(150)).is_ok(),
        Err(_) => false,
    }
}

fn live_models(port: &str) -> Vec<String> {
    let Ok(addr) = format!("127.0.0.1:{}", port).parse::<SocketAddr>() else {
        return vec![];
    };
    let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(300)) else {
        return vec![];
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let req = format!(
        "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
        port
    );
    if s.write_all(req.as_bytes()).is_err() {
        return vec![];
    }
    let mut buf = Vec::new();
    let _ = s.read_to_end(&mut buf);
    let text = String::from_utf8_lossy(&buf);
    let mut res = Vec::new();
    let mut rest: &str = &text;
    while let Some(i) = rest.find("\"id\"") {
        rest = &rest[i + 4..];
        let r = rest.trim_start().trim_start_matches(':').trim_start();
        if let Some(r) = r.strip_prefix('"') {
            if let Some(e) = r.find('"') {
                let id = &r[..e];
                if id.starts_with("gemini-") && !res.iter().any(|x| x == id) {
                    res.push(id.to_string());
                }
            }
        }
    }
    res
}

fn find_node(root: &PathBuf) -> Option<PathBuf> {
    // Bundled runtime (release folder) wins over anything on PATH.
    for b in [root.join("node").join("node.exe"), root.join("node.exe")] {
        if b.is_file() {
            return Some(b);
        }
    }
    if let Some(path) = std::env::var_os("PATH") {
        for d in std::env::split_paths(&path) {
            let c = d.join("node.exe");
            if c.is_file() {
                return Some(c);
            }
        }
    }
    let mut cands = vec![];
    for var in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Some(b) = std::env::var_os(var) {
            let b = PathBuf::from(b);
            cands.push(b.join("nodejs").join("node.exe"));
            cands.push(b.join("Programs").join("nodejs").join("node.exe"));
        }
    }
    if let Some(a) = std::env::var_os("APPDATA") {
        let nvm = PathBuf::from(a).join("nvm");
        cands.push(nvm.join("node.exe"));
        if let Ok(rd) = fs::read_dir(&nvm) {
            for e in rd.flatten() {
                cands.push(e.path().join("node.exe"));
            }
        }
    }
    cands.into_iter().find(|c| c.is_file())
}

struct State {
    child: Option<Child>,
    was_running: bool,
    out_off: u64,
    err_off: u64,
    masked: bool,
    quitting: bool,
    last_check: Option<Instant>,
    upd_busy: bool,
    upd_available: Option<update::Release>,
    upd_notified: Option<String>,
}

enum UpdMsg {
    Checked(Result<Option<update::Release>, String>, bool),
    Downloaded(Result<PathBuf, String>),
}

const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_NAME: &str = "VertexOpenAIProxyGui";

fn reg(args: &[&str]) -> bool {
    Command::new("reg").args(args).creation_flags(CREATE_NO_WINDOW).output().map(|o| o.status.success()).unwrap_or(false)
}
fn boot_enabled() -> bool { reg(&["query", RUN_KEY, "/v", RUN_NAME]) }
fn set_boot(on: bool) -> bool {
    if on {
        let exe = std::env::current_exe().unwrap_or_default();
        let val = format!("\"{}\" --minimized", exe.display());
        reg(&["add", RUN_KEY, "/v", RUN_NAME, "/t", "REG_SZ", "/d", &val, "/f"])
    } else {
        reg(&["delete", RUN_KEY, "/v", RUN_NAME, "/f"])
    }
}

struct Gui {
    paths: Paths,
    state: RefCell<State>,
    upd_slot: Arc<Mutex<Option<UpdMsg>>>,
    window: nwg::Window,
    status: nwg::Label,
    project: nwg::TextInput,
    mask_btn: nwg::Button,
    location: nwg::TextInput,
    model: nwg::TextInput,
    model_pick: nwg::ComboBox<String>,
    port: nwg::TextInput,
    start_btn: nwg::Button,
    stop_btn: nwg::Button,
    restart_btn: nwg::Button,
    save_btn: nwg::Button,
    chk_boot: nwg::CheckBox,
    chk_auto: nwg::CheckBox,
    hint: nwg::Label,
    log_label: nwg::Label,
    log: nwg::TextBox,
    upd_btn: nwg::Button,
    timer: nwg::Timer,
    tray: nwg::TrayNotification,
    tray_menu: nwg::Menu,
    mi_open: nwg::MenuItem,
    mi_restart: nwg::MenuItem,
    mi_update: nwg::MenuItem,
    mi_quit: nwg::MenuItem,
}

impl Gui {
    fn log(&self, s: &str) {
        self.log.append(&format!("[GUI] {}\r\n", s));
        self.log.scroll_lastline();
    }

    fn set_status(&self, running: bool) {
        let t = if running { "Status: Running" } else { "Status: Stopped" };
        self.status.set_text(t);
        self.tray.set_tip(&format!("Vertex OpenAI Proxy - {}", if running { "Running" } else { "Stopped" }));
    }

    fn form(&self) -> [String; 4] {
        let nz = |s: String, d: &str| if s.trim().is_empty() { d.to_string() } else { s.trim().to_string() };
        [
            self.project.text().trim().to_string(),
            nz(self.location.text(), "global"),
            nz(self.model.text(), "gemini-3.7-flash"),
            nz(self.port.text(), "3000"),
        ]
    }

    fn load_form(&self) {
        let v = read_env(&self.paths);
        self.project.set_text(&v[0]);
        self.location.set_text(&v[1]);
        self.model.set_text(&v[2]);
        self.port.set_text(&v[3]);
        let mut models = live_models(&v[3]);
        for m in FALLBACK_MODELS {
            if !models.iter().any(|x| x == m) {
                models.push(m.to_string());
            }
        }
        self.model_pick.set_collection(models);
        let st = |b: bool| if b { nwg::CheckBoxState::Checked } else { nwg::CheckBoxState::Unchecked };
        self.chk_boot.set_check_state(st(boot_enabled()));
        self.chk_auto.set_check_state(st(self.auto_server()));
    }

    fn auto_server(&self) -> bool {
        fs::read_to_string(&self.paths.settings).map(|t| t.contains("auto_start_server=1")).unwrap_or(false)
    }

    fn running(&self) -> bool {
        let mut st = self.state.borrow_mut();
        match st.child.as_mut() {
            Some(c) => matches!(c.try_wait(), Ok(None)),
            None => false,
        }
    }

    fn start(&self) {
        if self.running() {
            self.log("Already running.");
            return;
        }
        let f = self.form();
        if f[0].is_empty() {
            self.log("ERROR: Please enter a Project ID.");
            nwg::modal_info_message(&self.window, "Required", "Please enter a Project ID.");
            return;
        }
        if f != read_env(&self.paths) {
            match write_env(&self.paths, &f) {
                Ok(_) => self.log("Detected changed settings; saved to .env."),
                Err(e) => self.log(&format!("ERROR: could not write .env: {}", e)),
            }
        }
        if port_in_use(&f[3]) {
            self.log(&format!(
                "ERROR: Port {} is already in use by another process (an older server instance?). Stop it first or change the port.",
                f[3]
            ));
            return;
        }
        let Some(node) = find_node(&self.paths.root) else {
            self.log("ERROR: Could not find the node executable. Please make sure Node.js is installed.");
            nwg::modal_error_message(&self.window, "Error", "Could not find the node executable.");
            return;
        };
        let (Ok(out), Ok(err)) = (File::create(&self.paths.out_log), File::create(&self.paths.err_log)) else {
            self.log("ERROR: could not create log files.");
            return;
        };
        match Command::new(node)
            .arg("index.js")
            .current_dir(&self.paths.root)
            .creation_flags(CREATE_NO_WINDOW)
            .stdout(out)
            .stderr(err)
            .spawn()
        {
            Ok(c) => {
                let mut st = self.state.borrow_mut();
                st.child = Some(c);
                st.was_running = true;
                st.out_off = 0;
                st.err_off = 0;
                drop(st);
                self.set_status(true);
                self.log("Server started.");
            }
            Err(e) => {
                self.log(&format!("ERROR: Failed to start server: {}", e));
                nwg::modal_error_message(&self.window, "Error", &format!("Failed to start server: {}", e));
            }
        }
    }

    fn stop(&self) {
        if !self.running() {
            self.log("No server is running.");
            self.set_status(false);
            return;
        }
        {
            let mut st = self.state.borrow_mut();
            if let Some(c) = st.child.as_mut() {
                let _ = c.kill();
                let _ = c.wait();
            }
            st.child = None;
            st.was_running = false;
        }
        // Wait for the port to actually clear (avoids EADDRINUSE on restart).
        let port = self.port.text().trim().to_string();
        if !port.is_empty() {
            for _ in 0..20 {
                if !port_in_use(&port) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(150));
            }
        }
        self.set_status(false);
        self.log("Server stopped.");
    }

    fn restart(&self) {
        self.stop();
        std::thread::sleep(Duration::from_millis(300));
        self.start();
    }

    fn save_restart(&self) {
        let f = self.form();
        if f[0].is_empty() {
            self.log("ERROR: Please enter a Project ID.");
            nwg::modal_info_message(&self.window, "Required", "Please enter a Project ID.");
            return;
        }
        if let Err(e) = write_env(&self.paths, &f) {
            self.log(&format!("ERROR: could not write .env: {}", e));
            return;
        }
        self.log("Saved .env. Restarting server...");
        self.restart();
    }

    fn show_window(&self) {
        self.window.set_visible(true);
        self.window.restore();
        self.window.set_focus();
    }

    fn quit(&self) {
        self.state.borrow_mut().quitting = true;
        self.stop();
        self.tray.set_visibility(false);
        let _ = fs::remove_file(&self.paths.command);
        nwg::stop_thread_dispatch();
        std::process::exit(0);
    }

    fn read_new(&self, path: &PathBuf, err: bool) {
        let off = {
            let st = self.state.borrow();
            if err { st.err_off } else { st.out_off }
        };
        let Ok(mut f) = File::open(path) else { return };
        let Ok(len) = f.metadata().map(|m| m.len()) else { return };
        if len <= off {
            return;
        }
        if f.seek(SeekFrom::Start(off)).is_err() {
            return;
        }
        let mut buf = Vec::new();
        let _ = f.take(len - off).read_to_end(&mut buf);
        {
            let mut st = self.state.borrow_mut();
            if err { st.err_off = len } else { st.out_off = len }
        }
        let text = String::from_utf8_lossy(&buf).replace("\r\n", "\n").replace('\n', "\r\n");
        self.log.append(&text);
        self.log.scroll_lastline();
    }

    fn tick(&self) {
        let msg = self.upd_slot.lock().unwrap().take();
        if let Some(m) = msg {
            self.on_update_msg(m);
        }
        let due = self.state.borrow().last_check.map_or(false, |t| t.elapsed() >= CHECK_EVERY);
        if due {
            self.check_update(false);
        }
        self.read_new(&self.paths.out_log.clone(), false);
        self.read_new(&self.paths.err_log.clone(), true);
        let exited = {
            let mut st = self.state.borrow_mut();
            let mut ex = false;
            if st.was_running {
                if let Some(c) = st.child.as_mut() {
                    if matches!(c.try_wait(), Ok(Some(_))) {
                        ex = true;
                    }
                }
                if ex {
                    st.was_running = false;
                }
            }
            ex
        };
        if exited {
            self.set_status(false);
            self.log("Server process exited.");
        }
        // External commands (SendCommand.vbs / second launch) via a command file.
        if let Ok(cmd) = fs::read_to_string(&self.paths.command) {
            let _ = fs::remove_file(&self.paths.command);
            match cmd.trim() {
                "open" => self.show_window(),
                "restart" => self.restart(),
                "quit" => self.quit(),
                _ => {}
            }
        }
    }

    // ---- auto-update ----
    fn check_update(&self, manual: bool) {
        {
            let mut st = self.state.borrow_mut();
            if st.upd_busy {
                drop(st);
                if manual {
                    self.log("Update: already checking/downloading.");
                }
                return;
            }
            st.upd_busy = true;
            st.last_check = Some(Instant::now());
        }
        if manual {
            self.log("Checking GitHub for updates...");
        }
        let slot = self.upd_slot.clone();
        std::thread::spawn(move || {
            let r = update::check();
            *slot.lock().unwrap() = Some(UpdMsg::Checked(r, manual));
        });
    }

    fn set_update_ui(&self, rel: Option<&update::Release>) {
        let t = match rel {
            Some(r) => format!("Install Update v{}", r.version),
            None => "Check for Updates".to_string(),
        };
        self.upd_btn.set_text(&t);
    }

    fn on_update_msg(&self, msg: UpdMsg) {
        self.state.borrow_mut().upd_busy = false;
        match msg {
            UpdMsg::Checked(Err(e), manual) => {
                self.log(&format!("Update check failed: {}", e));
                if manual {
                    nwg::modal_error_message(&self.window, "Update", &format!("Update check failed:\n{}", e));
                }
            }
            UpdMsg::Checked(Ok(None), manual) => {
                self.state.borrow_mut().upd_available = None;
                self.set_update_ui(None);
                if manual {
                    let m = format!("You are on the latest version (v{}).", update::current_version());
                    self.log(&m);
                    nwg::modal_info_message(&self.window, "Update", &m);
                }
            }
            UpdMsg::Checked(Ok(Some(rel)), manual) => {
                let first = {
                    let mut st = self.state.borrow_mut();
                    st.upd_available = Some(rel.clone());
                    let first = st.upd_notified.as_deref() != Some(rel.version.as_str());
                    st.upd_notified = Some(rel.version.clone());
                    first
                };
                self.set_update_ui(Some(&rel));
                if first || manual {
                    self.log(&format!("Update available: v{} (installed v{}).", rel.version, update::current_version()));
                }
                if manual || (first && self.window.visible()) {
                    self.prompt_install();
                } else if first {
                    let txt = format!("Version {} is available. Right-click the tray icon to install.", rel.version);
                    self.tray.show(&txt, Some("Vertex OpenAI Proxy update"), Some(nwg::TrayNotificationFlags::INFO_ICON), None);
                }
            }
            UpdMsg::Downloaded(Err(e)) => {
                self.log(&format!("Update download failed: {}", e));
                nwg::modal_error_message(&self.window, "Update", &format!("Download failed:\n{}", e));
            }
            UpdMsg::Downloaded(Ok(payload)) => {
                let root = self.paths.root.clone();
                match update::apply(&payload, &root) {
                    Ok(()) => {
                        self.log("Update downloaded; restarting to install...");
                        self.quit();
                    }
                    Err(e) => {
                        self.log(&format!("Update failed: {}", e));
                        nwg::modal_error_message(&self.window, "Update", &format!("Update failed:\n{}", e));
                    }
                }
            }
        }
    }

    /// Asks the user, then downloads in the background; installing happens in
    /// on_update_msg once the download finishes.
    fn prompt_install(&self) {
        let Some(rel) = self.state.borrow().upd_available.clone() else {
            self.check_update(true);
            return;
        };
        if self.state.borrow().upd_busy {
            return;
        }
        if let Err(e) = update::install_dir(&self.paths.root) {
            self.log(&format!("Update v{} available, but cannot self-update: {}", rel.version, e));
            return;
        }
        self.show_window();
        let q = format!(
            "Version {} is available (installed: {}).\n\nDownload and install it now? The server will stop, the app will restart, and your .env settings are kept.",
            rel.version,
            update::current_version()
        );
        let p = nwg::MessageParams {
            title: "Update available",
            content: &q,
            buttons: nwg::MessageButtons::YesNo,
            icons: nwg::MessageIcons::Question,
        };
        if nwg::modal_message(&self.window, &p) != nwg::MessageChoice::Yes {
            self.log("Update postponed.");
            return;
        }
        self.state.borrow_mut().upd_busy = true;
        self.log(&format!("Downloading v{} ...", rel.version));
        let slot = self.upd_slot.clone();
        std::thread::spawn(move || {
            let r = update::download(&rel);
            *slot.lock().unwrap() = Some(UpdMsg::Downloaded(r));
        });
    }

    fn layout(&self) {
        let (w, h) = self.window.size();
        let (w, h) = (w as i32, h as i32);
        let lw = (w - 40 - 16).max(100) as u32;
        let top = 354;
        let lh = (h - top - 60).max(60) as u32;
        self.log.set_size(lw, lh);
    }
}

fn handle(gui: &Rc<Gui>, evt: nwg::Event, data: nwg::EventData, h: nwg::ControlHandle) {
    use nwg::Event as E;
    match evt {
        E::OnWindowClose => {
            if h == gui.window.handle && !gui.state.borrow().quitting {
                if let nwg::EventData::OnWindowClose(d) = &data {
                    d.close(false);
                }
                gui.window.set_visible(false); // hide to tray
            }
        }
        E::OnResize | E::OnWindowMaximize => gui.layout(),
        E::OnTimerTick => gui.tick(),
        E::OnButtonClick => {
            if h == gui.start_btn.handle {
                gui.start();
            } else if h == gui.stop_btn.handle {
                gui.stop();
            } else if h == gui.restart_btn.handle {
                gui.restart();
            } else if h == gui.save_btn.handle {
                gui.save_restart();
            } else if h == gui.upd_btn.handle {
                gui.prompt_install();
            } else if h == gui.chk_boot.handle {
                let on = gui.chk_boot.check_state() == nwg::CheckBoxState::Checked;
                if set_boot(on) {
                    gui.log(if on { "Enabled start with Windows." } else { "Disabled start with Windows." });
                } else {
                    gui.log("ERROR: could not update the Windows startup entry.");
                }
            } else if h == gui.chk_auto.handle {
                let on = gui.chk_auto.check_state() == nwg::CheckBoxState::Checked;
                let _ = fs::write(&gui.paths.settings, if on { "auto_start_server=1
" } else { "auto_start_server=0
" });
                gui.log(if on { "Server will auto-start on launch." } else { "Server auto-start disabled." });
            } else if h == gui.mask_btn.handle {
                let masked = {
                    let mut st = gui.state.borrow_mut();
                    st.masked = !st.masked;
                    st.masked
                };
                gui.project.set_password_char(if masked { Some('*') } else { None });
                gui.mask_btn.set_text(if masked { "Show" } else { "Hide" });
            }
        }
        E::OnComboxBoxSelection => {
            if h == gui.model_pick.handle {
                if let Some(s) = gui.model_pick.selection_string() {
                    gui.model.set_text(&s);
                }
            }
        }
        E::OnContextMenu => {
            if h == gui.tray.handle {
                let (x, y) = nwg::GlobalCursor::position();
                gui.tray_menu.popup(x, y);
            }
        }
        E::OnMousePress(nwg::MousePressEvent::MousePressLeftUp) => {
            if h == gui.tray.handle {
                gui.show_window();
            }
        }
        E::OnMenuItemSelected => {
            if h == gui.mi_open.handle {
                gui.show_window();
            } else if h == gui.mi_restart.handle {
                gui.restart();
            } else if h == gui.mi_update.handle {
                gui.prompt_install();
            } else if h == gui.mi_quit.handle {
                gui.quit();
            }
        }
        _ => {}
    }
}

fn single_instance(p: &Paths) -> bool {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name: Vec<u16> = "Local\\VertexOpenAIProxyGuiRust\0".encode_utf16().collect();
    unsafe {
        let m = CreateMutexW(std::ptr::null(), 1, name.as_ptr());
        if m == 0 || GetLastError() == ERROR_ALREADY_EXISTS {
            // Ask the running instance to show itself, then exit.
            let _ = fs::write(&p.command, "open");
            return false;
        }
    }
    true // handle intentionally leaked: lives as long as the process
}

fn main() {
    let paths = find_paths();
    if !single_instance(&paths) {
        return;
    }
    nwg::init().expect("init failed");
    let _ = nwg::Font::set_global_family("Segoe UI");

    let mut g = Gui {
        paths,
        state: RefCell::new(State { child: None, was_running: false, out_off: 0, err_off: 0, masked: true, quitting: false, last_check: None, upd_busy: false, upd_available: None, upd_notified: None }),
        upd_slot: Arc::new(Mutex::new(None)),
        window: Default::default(),
        status: Default::default(),
        project: Default::default(),
        mask_btn: Default::default(),
        location: Default::default(),
        model: Default::default(),
        model_pick: Default::default(),
        port: Default::default(),
        start_btn: Default::default(),
        stop_btn: Default::default(),
        restart_btn: Default::default(),
        save_btn: Default::default(),
        chk_boot: Default::default(),
        chk_auto: Default::default(),
        hint: Default::default(),
        log_label: Default::default(),
        log: Default::default(),
        upd_btn: Default::default(),
        timer: Default::default(),
        tray: Default::default(),
        tray_menu: Default::default(),
        mi_open: Default::default(),
        mi_restart: Default::default(),
        mi_update: Default::default(),
        mi_quit: Default::default(),
    };

    let mut icon = nwg::Icon::default();
    nwg::Icon::builder().source_system(Some(nwg::OemIcon::Information)).build(&mut icon).unwrap();

    nwg::Window::builder()
        .size((720, 640))
        .position((300, 120))
        .title(&format!("Vertex OpenAI Proxy v{}", update::current_version()))
        .icon(Some(&icon))
        .build(&mut g.window)
        .unwrap();
    let w = &g.window;

    nwg::Label::builder().parent(w).text("Status: Stopped").position((20, 14)).size((300, 24)).build(&mut g.status).unwrap();

    let label = |t: &str, y: i32, o: &mut nwg::Label| {
        nwg::Label::builder().parent(w).text(t).position((20, y + 4)).size((170, 24)).build(o).unwrap();
    };
    let mut l1 = Default::default();
    let mut l2 = Default::default();
    let mut l3 = Default::default();
    let mut l4 = Default::default();
    label("Google Cloud Project ID", 52, &mut l1);
    label("Location", 92, &mut l2);
    label("Gemini Model", 132, &mut l3);
    label("Port", 172, &mut l4);

    nwg::TextInput::builder().parent(w).position((200, 52)).size((380, 28)).password(Some('*')).build(&mut g.project).unwrap();
    nwg::Button::builder().parent(w).text("Show").position((590, 52)).size((90, 28)).build(&mut g.mask_btn).unwrap();
    nwg::TextInput::builder().parent(w).position((200, 92)).size((480, 28)).build(&mut g.location).unwrap();
    nwg::TextInput::builder().parent(w).position((200, 132)).size((300, 28)).build(&mut g.model).unwrap();
    nwg::ComboBox::builder().parent(w).position((510, 132)).size((170, 28)).collection(Vec::<String>::new()).build(&mut g.model_pick).unwrap();
    nwg::TextInput::builder().parent(w).position((200, 172)).size((480, 28)).build(&mut g.port).unwrap();

    let btn = |t: &str, x: i32, o: &mut nwg::Button| {
        nwg::Button::builder().parent(w).text(t).position((x, 220)).size((160, 38)).build(o).unwrap();
    };
    btn("Start", 20, &mut g.start_btn);
    btn("Stop", 190, &mut g.stop_btn);
    btn("Restart", 360, &mut g.restart_btn);
    btn("Save && Restart", 530, &mut g.save_btn);

    nwg::CheckBox::builder().parent(w).text("Start with Windows (boot, hidden in tray)").position((20, 268)).size((320, 24)).build(&mut g.chk_boot).unwrap();
    nwg::CheckBox::builder().parent(w).text("Auto-start server on launch").position((350, 268)).size((330, 24)).build(&mut g.chk_auto).unwrap();
    nwg::Label::builder().parent(w)
        .text("Closing this window keeps the app running in the system tray. Right-click the tray icon to quit.")
        .position((20, 300)).size((660, 20)).build(&mut g.hint).unwrap();
    nwg::Label::builder().parent(w).text("Log").position((20, 330)).size((200, 20)).build(&mut g.log_label).unwrap();
    nwg::TextBox::builder().parent(w).position((20, 354)).size((660, 230)).readonly(true)
        .flags(nwg::TextBoxFlags::VISIBLE | nwg::TextBoxFlags::VSCROLL | nwg::TextBoxFlags::TAB_STOP)
        .build(&mut g.log).unwrap();

    nwg::Button::builder().parent(w).text("Check for Updates").position((500, 324)).size((180, 26)).build(&mut g.upd_btn).unwrap();

    nwg::Timer::builder().parent(w).interval(400).stopped(false).build(&mut g.timer).unwrap();

    nwg::TrayNotification::builder().parent(w).icon(Some(&icon)).tip(Some("Vertex OpenAI Proxy - Stopped")).build(&mut g.tray).unwrap();
    nwg::Menu::builder().parent(w).popup(true).build(&mut g.tray_menu).unwrap();
    nwg::MenuItem::builder().parent(&g.tray_menu).text("Open").build(&mut g.mi_open).unwrap();
    nwg::MenuItem::builder().parent(&g.tray_menu).text("Restart Server").build(&mut g.mi_restart).unwrap();
    nwg::MenuItem::builder().parent(&g.tray_menu).text("Check for / Install Updates").build(&mut g.mi_update).unwrap();
    nwg::MenuItem::builder().parent(&g.tray_menu).text("Quit").build(&mut g.mi_quit).unwrap();
    g.load_form();
    g.layout();
    let gui = Rc::new(g);
    let g2 = gui.clone();
    let _h = nwg::full_bind_event_handler(&gui.window.handle, move |e, d, h| handle(&g2, e, d, h));
    if std::env::args().any(|a| a == "--minimized") {
        gui.window.set_visible(false);
    }
    if gui.auto_server() {
        gui.start();
    }
    gui.check_update(false); // on launch; tick() repeats it every 24h

    nwg::dispatch_thread_events();
}
