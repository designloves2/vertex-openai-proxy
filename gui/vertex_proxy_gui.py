#!/usr/bin/env python3
"""
Vertex OpenAI Proxy - tray-based control panel.

Starts/stops/restarts the Node.js proxy server, edits .env (project id,
location, model, port), and minimizes to the Windows system tray instead
of leaving a console window open.

Run with: pythonw vertex_proxy_gui.py   (no console window)
      or: python  vertex_proxy_gui.py   (for debugging, shows console)
"""
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
import urllib.request
from tkinter import messagebox

import customtkinter as ctk

try:
    import pystray
    from PIL import Image, ImageDraw
except ImportError:
    pystray = None
    Image = None
    ImageDraw = None

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
BEIGE = "#F1E3D3"
BLACK = "#1A1A1A"
BLACK_HOVER = "#333333"
WHITE = "#FFFFFF"
MUTED = "#5A4E42"
FONT_NAME = "Segoe UI" if sys.platform == "win32" else "Helvetica"

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_PATH = os.path.join(PROJECT_ROOT, ".env")

FALLBACK_MODELS = [
    "gemini-3.7-flash",
    "gemini-3.1-pro",
    "gemini-3.8-flash",
    "gemini-1.5-pro-002",
    "gemini-1.5-flash-002",
]

ENV_KEYS = ["GOOGLE_CLOUD_PROJECT_ID", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_MODEL_ID", "PORT"]

# Arbitrary local-only port used purely as a single-instance mutex: binding it
# fails if another copy of this GUI is already running.
SINGLE_INSTANCE_PORT = 47123
LOCK_PID_PATH = os.path.join(PROJECT_ROOT, ".gui-instance.lock")


def acquire_single_instance_lock():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", SINGLE_INSTANCE_PORT))
        s.listen(1)
        return s
    except OSError:
        s.close()
        return None


def read_lock_pid():
    try:
        with open(LOCK_PID_PATH, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None


def write_lock_pid():
    try:
        with open(LOCK_PID_PATH, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass


def kill_pid(pid):
    try:
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                            capture_output=True, timeout=5)
        else:
            os.kill(pid, 15)  # SIGTERM
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# .env helpers (only touch the keys we manage; leave everything else as-is)
# ---------------------------------------------------------------------------
def read_env():
    values = {"GOOGLE_CLOUD_PROJECT_ID": "", "GOOGLE_CLOUD_LOCATION": "global",
              "GOOGLE_CLOUD_MODEL_ID": "gemini-3.7-flash", "PORT": "3000"}
    if os.path.exists(ENV_PATH):
        # utf-8-sig: PowerShell's `Set-Content -Encoding UTF8` writes a BOM,
        # which (with plain "utf-8") gets glued onto the first line's key and
        # makes it fail to match, silently dropping that value from the form.
        with open(ENV_PATH, "r", encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if key in values:
                    values[key] = val.strip()
    return values


def write_env(values):
    lines = []
    seen = set()
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, "r", encoding="utf-8-sig") as f:
            for line in f:
                stripped = line.rstrip("\n")
                key = stripped.split("=", 1)[0].strip() if "=" in stripped else None
                if key in ENV_KEYS:
                    if key in seen:
                        # Drop duplicate/stale lines for a key we already wrote
                        # (e.g. leftover from the BOM bug above).
                        continue
                    lines.append(f"{key}={values[key]}")
                    seen.add(key)
                else:
                    lines.append(stripped)
    for key in ENV_KEYS:
        if key not in seen:
            lines.append(f"{key}={values[key]}")
    # Plain "utf-8" (no BOM) on write, so the file stays BOM-free going forward.
    with open(ENV_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def fetch_live_models(port):
    try:
        url = f"http://127.0.0.1:{port}/v1/models"
        with urllib.request.urlopen(url, timeout=1.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            ids = [m["id"] for m in data.get("data", [])]
            return [m for m in ids if m.startswith("gemini-")]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Main app
# ---------------------------------------------------------------------------
class ProxyGuiApp:
    def __init__(self, lock_socket=None):
        self.lock_socket = lock_socket

        ctk.set_appearance_mode("light")
        ctk.set_default_color_theme("dark-blue")

        self.root = ctk.CTk()
        self.root.title("Vertex OpenAI Proxy")
        try:
            self.root.configure(fg_color=BEIGE)
        except Exception:
            self.root.configure(bg=BEIGE)
        self.root.protocol("WM_DELETE_WINDOW", self.hide_to_tray)
        self.root.bind("<Unmap>", self._on_unmap)

        self.proc = None
        self.log_queue = queue.Queue()
        self.tray_icon = None

        self._build_ui()
        self._load_env_into_fields()

        # Size the window to fit its content exactly (no leftover margin),
        # instead of a guessed fixed geometry.
        self.root.update_idletasks()
        width = self.root.winfo_reqwidth()
        height = self.root.winfo_reqheight()
        self.root.geometry(f"{width}x{height}")
        self.root.minsize(width, 360)

        self.root.after(100, self._poll_log_queue)

    # -- UI ----------------------------------------------------------------
    def _build_ui(self):
        header = ctk.CTkLabel(self.root, text="Vertex OpenAI Proxy", bg_color=BEIGE,
                               text_color=BLACK, font=(FONT_NAME, 20, "bold"))
        header.pack(anchor="w", padx=20, pady=(20, 6))

        status_row = ctk.CTkFrame(self.root, fg_color=BEIGE)
        status_row.pack(anchor="w", padx=20, pady=(0, 14))
        self.status_dot = ctk.CTkLabel(status_row, text="●", text_color="#B23B3B",
                                        bg_color=BEIGE, font=(FONT_NAME, 12))
        self.status_dot.pack(side="left")
        self.status_label = ctk.CTkLabel(status_row, text="중지됨", bg_color=BEIGE,
                                          text_color=BLACK, font=(FONT_NAME, 11, "bold"))
        self.status_label.pack(side="left", padx=(6, 0))

        form = ctk.CTkFrame(self.root, fg_color=BEIGE)
        form.pack(fill="x", padx=20)

        self.entry_project = self._add_field(form, "Google Cloud Project ID", maskable=True)
        self.entry_location = self._add_field(form, "리전 (Location)")
        self.combo_model = self._add_model_field(form, "Gemini 모델")
        self.entry_port = self._add_field(form, "포트 (Port)")

        btn_row = ctk.CTkFrame(self.root, fg_color=BEIGE)
        btn_row.pack(fill="x", padx=20, pady=(16, 10))

        self.btn_start = self._make_button(btn_row, "시작", self.start_server, width=90)
        self.btn_stop = self._make_button(btn_row, "정지", self.stop_server, width=90)
        self.btn_restart = self._make_button(btn_row, "재시작", self.restart_server, width=90)
        self.btn_save = self._make_button(btn_row, "저장 후 재시작", self.save_and_restart, width=150)

        for b in (self.btn_start, self.btn_stop, self.btn_restart, self.btn_save):
            b.pack(side="left", padx=(0, 10))

        tray_hint = ctk.CTkLabel(
            self.root,
            text="창을 닫으면 트레이로 최소화됩니다. 완전히 종료하려면 트레이 아이콘 메뉴를 사용하세요.",
            bg_color=BEIGE, text_color=MUTED, font=(FONT_NAME, 9),
        )
        tray_hint.pack(anchor="w", padx=20, pady=(0, 10))

        # -- log (collapsible / accordion) --
        log_header = ctk.CTkFrame(self.root, fg_color=BEIGE)
        log_header.pack(fill="x", padx=20)
        self.log_toggle_label = ctk.CTkLabel(log_header, text="▼  로그", bg_color=BEIGE,
                                              text_color=BLACK, font=(FONT_NAME, 10, "bold"),
                                              cursor="hand2")
        self.log_toggle_label.pack(side="left")
        self.log_toggle_label.bind("<Button-1>", lambda e: self._toggle_log())

        self.log_visible = True
        self.log_frame = ctk.CTkFrame(self.root, fg_color=BLACK, corner_radius=14)
        self.log_frame.pack(fill="both", expand=True, padx=20, pady=(6, 20))
        self.log_text = ctk.CTkTextbox(self.log_frame, fg_color=BLACK, text_color=WHITE,
                                        corner_radius=14, border_width=0,
                                        font=("Consolas", 10), wrap="word", height=220)
        self.log_text.pack(fill="both", expand=True, padx=4, pady=4)
        self.log_text.configure(state="disabled")

    def _make_button(self, parent, text, command, width=90):
        return ctk.CTkButton(parent, text=text, command=command, width=width, height=36,
                              corner_radius=14, fg_color=BLACK, hover_color=BLACK_HOVER,
                              text_color=WHITE, font=(FONT_NAME, 11, "bold"), border_width=0)

    def _toggle_log(self):
        self.log_visible = not self.log_visible
        if self.log_visible:
            self.log_frame.pack(fill="both", expand=True, padx=20, pady=(6, 20))
            self.log_toggle_label.configure(text="▼  로그")
        else:
            self.log_frame.pack_forget()
            self.log_toggle_label.configure(text="▶  로그")
        self.root.after(10, self._resize_to_content)

    def _resize_to_content(self):
        width = self.root.winfo_width()
        x = self.root.winfo_x()
        y = self.root.winfo_y()
        self.root.update_idletasks()
        height = self.root.winfo_reqheight()
        self.root.geometry(f"{width}x{height}+{x}+{y}")

    def _add_field(self, parent, label_text, maskable=False):
        row = ctk.CTkFrame(parent, fg_color=BEIGE)
        row.pack(fill="x", pady=5)
        ctk.CTkLabel(row, text=label_text, bg_color=BEIGE, text_color=BLACK,
                     font=(FONT_NAME, 10, "bold"), width=190, anchor="w").pack(side="left")

        entry_width = 400 if maskable else 440
        entry = ctk.CTkEntry(row, width=entry_width, height=36, corner_radius=14,
                              fg_color=BLACK, text_color=WHITE, border_width=0,
                              font=(FONT_NAME, 11))
        entry.pack(side="left")

        if maskable:
            entry._masked = True
            entry.configure(show="•")
            toggle = ctk.CTkButton(row, text="\U0001F441", width=36, height=36, corner_radius=12,
                                    fg_color=BLACK, hover_color=BLACK_HOVER, text_color=WHITE,
                                    font=(FONT_NAME, 12), border_width=0,
                                    command=lambda: self._toggle_mask(entry, toggle))
            toggle.pack(side="left", padx=(6, 0))
        return entry

    def _toggle_mask(self, entry, toggle_button):
        masked = not getattr(entry, "_masked", True)
        entry._masked = masked
        entry.configure(show="•" if masked else "")
        toggle_button.configure(text="\U0001F441" if masked else "\U0001F576")

    def _add_model_field(self, parent, label_text):
        row = ctk.CTkFrame(parent, fg_color=BEIGE)
        row.pack(fill="x", pady=5)
        ctk.CTkLabel(row, text=label_text, bg_color=BEIGE, text_color=BLACK,
                     font=(FONT_NAME, 10, "bold"), width=190, anchor="w").pack(side="left")
        combo = ctk.CTkComboBox(row, values=FALLBACK_MODELS, width=440, height=36,
                                 corner_radius=14, fg_color=BLACK, text_color=WHITE,
                                 button_color=BLACK_HOVER, button_hover_color=BLACK_HOVER,
                                 dropdown_fg_color=BLACK, dropdown_text_color=WHITE,
                                 border_width=0, font=(FONT_NAME, 11))
        combo.pack(side="left")
        return combo

    # -- env <-> fields ------------------------------------------------------
    def _load_env_into_fields(self):
        values = read_env()
        self.entry_project.delete(0, tk.END)
        self.entry_project.insert(0, values["GOOGLE_CLOUD_PROJECT_ID"])
        self.entry_location.delete(0, tk.END)
        self.entry_location.insert(0, values["GOOGLE_CLOUD_LOCATION"])
        self.entry_port.delete(0, tk.END)
        self.entry_port.insert(0, values["PORT"])
        self.combo_model.set(values["GOOGLE_CLOUD_MODEL_ID"])

        live_models = fetch_live_models(values["PORT"])
        merged = list(dict.fromkeys(live_models + FALLBACK_MODELS))
        self.combo_model.configure(values=merged)

    def _fields_to_env(self):
        return {
            "GOOGLE_CLOUD_PROJECT_ID": self.entry_project.get().strip(),
            "GOOGLE_CLOUD_LOCATION": self.entry_location.get().strip() or "global",
            "GOOGLE_CLOUD_MODEL_ID": self.combo_model.get().strip() or "gemini-3.7-flash",
            "PORT": self.entry_port.get().strip() or "3000",
        }

    def _sync_env_if_changed(self):
        """Compare the form fields against the .env on disk; save if they differ.
        Returns False (and shows a warning) only if the fields are invalid."""
        current = read_env()
        new_values = self._fields_to_env()
        if not new_values["GOOGLE_CLOUD_PROJECT_ID"]:
            messagebox.showwarning("확인 필요", "Project ID를 입력해주세요.")
            return False
        if current != new_values:
            write_env(new_values)
            self._append_log("[GUI] 변경된 설정을 감지해 .env에 저장했습니다.\n")
        return True

    # -- server process control ----------------------------------------------
    def _append_log(self, line):
        self.log_queue.put(line)

    def _poll_log_queue(self):
        try:
            while True:
                line = self.log_queue.get_nowait()
                self.log_text.configure(state="normal")
                self.log_text.insert(tk.END, line)
                self.log_text.see(tk.END)
                self.log_text.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(150, self._poll_log_queue)

    def _set_status(self, running):
        color = "#3B8F5C" if running else "#B23B3B"
        text = "실행 중" if running else "중지됨"
        self.status_dot.configure(text_color=color)
        self.status_label.configure(text=text)

    def start_server(self):
        if self.proc and self.proc.poll() is None:
            self._append_log("[GUI] 이미 실행 중입니다.\n")
            return
        if not self._sync_env_if_changed():
            return
        node_path = shutil.which("node")
        if not node_path:
            messagebox.showerror("오류", "node 실행 파일을 찾을 수 없습니다. Node.js가 설치되어 있는지 확인해주세요.")
            return

        creationflags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        try:
            self.proc = subprocess.Popen(
                [node_path, "index.js"],
                cwd=PROJECT_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                creationflags=creationflags,
            )
        except Exception as exc:
            messagebox.showerror("오류", f"서버 시작 실패: {exc}")
            return

        self._set_status(True)
        self._append_log("[GUI] 서버를 시작했습니다.\n")
        threading.Thread(target=self._read_process_output, daemon=True).start()

    def _read_process_output(self):
        proc = self.proc
        if not proc or not proc.stdout:
            return
        for line in iter(proc.stdout.readline, ""):
            self._append_log(line)
        proc.stdout.close()
        self.root.after(0, lambda: self._set_status(False))
        self._append_log("[GUI] 서버 프로세스가 종료되었습니다.\n")

    def stop_server(self):
        if not self.proc or self.proc.poll() is not None:
            self._append_log("[GUI] 실행 중인 서버가 없습니다.\n")
            self._set_status(False)
            return
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self._set_status(False)
        self._append_log("[GUI] 서버를 정지했습니다.\n")

    def restart_server(self):
        self.stop_server()
        self.root.after(300, self.start_server)

    def save_and_restart(self):
        values = self._fields_to_env()
        if not values["GOOGLE_CLOUD_PROJECT_ID"]:
            messagebox.showwarning("확인 필요", "Project ID를 입력해주세요.")
            return
        write_env(values)
        self._append_log("[GUI] .env를 저장했습니다. 서버를 재시작합니다...\n")
        self.restart_server()

    # -- tray -----------------------------------------------------------------
    def _make_tray_image(self):
        if Image is None:
            return None
        size = 64
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=16, fill=(26, 26, 26, 255))
        draw.text((size / 2 - 8, size / 2 - 14), "V", fill=(255, 255, 255, 255))
        return img

    def _on_unmap(self, _event):
        if self.root.state() == "iconic":
            self.hide_to_tray()

    def hide_to_tray(self):
        self.root.withdraw()
        if pystray is None:
            messagebox.showinfo(
                "트레이 사용 불가",
                "pystray/Pillow가 설치되어 있지 않아 트레이로 내려갈 수 없습니다.\n"
                "설치 스크립트를 다시 실행하거나 'pip install -r gui/requirements.txt'를 실행해주세요.\n"
                "창을 다시 열려면 이 앱을 재실행하세요.",
            )
            return
        if self.tray_icon is None:
            image = self._make_tray_image()
            menu = pystray.Menu(
                pystray.MenuItem("열기", self._show_from_tray, default=True),
                pystray.MenuItem("서버 재시작", lambda: self.root.after(0, self.restart_server)),
                pystray.MenuItem("GUI 재시작 (프로세스 재시작)", self._restart_app_from_tray),
                pystray.MenuItem("완전히 종료", self._quit_from_tray),
            )
            self.tray_icon = pystray.Icon("vertex-openai-proxy", image, "Vertex OpenAI Proxy", menu)
            threading.Thread(target=self.tray_icon.run, daemon=True).start()

    def _show_from_tray(self, _icon=None, _item=None):
        self.root.after(0, self._deiconify)

    def _deiconify(self):
        self.root.deiconify()
        self.root.state("normal")
        self.root.lift()
        self.root.focus_force()

    def _quit_from_tray(self, _icon=None, _item=None):
        self._shutdown(relaunch=False)

    def _restart_app_from_tray(self, _icon=None, _item=None):
        self._shutdown(relaunch=True)

    def _shutdown(self, relaunch):
        """Tears down the app and (optionally) relaunches a fresh process.

        pystray menu callbacks run on pystray's own background thread, not
        the Tk main thread, and Tkinter isn't reliably thread-safe — under
        some timing, root.after()/root.destroy() calls from that thread never
        actually fire, leaving a zombie process holding the single-instance
        port open forever (every future launch then just sees "already
        running" and does nothing). A watchdog timer guarantees the process
        dies regardless of what the Tk main loop is doing.
        """
        threading.Timer(1.5, lambda: os._exit(0)).start()

        try:
            self.stop_server()
        except Exception:
            pass
        if self.tray_icon:
            try:
                self.tray_icon.stop()
            except Exception:
                pass
        if self.lock_socket:
            try:
                self.lock_socket.close()
            except Exception:
                pass
        if not relaunch:
            try:
                os.remove(LOCK_PID_PATH)
            except Exception:
                pass
        if relaunch:
            try:
                subprocess.Popen([sys.executable, os.path.abspath(__file__)], cwd=PROJECT_ROOT)
            except Exception:
                pass
        try:
            self.root.after(0, self.root.destroy)
        except Exception:
            pass

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    lock_socket = acquire_single_instance_lock()

    if lock_socket is None:
        existing_pid = read_lock_pid()
        pid_note = f" (PID {existing_pid})" if existing_pid else ""

        _root = tk.Tk()
        _root.withdraw()
        proceed = messagebox.askyesno(
            "Vertex OpenAI Proxy",
            f"이미 실행 중인 인스턴스가 있습니다{pid_note}.\n\n"
            "기존 실행을 종료하고 새로 열까요?\n\n"
            "예 → 기존 실행 종료 후 열기\n"
            "아니오 → 닫기",
        )
        _root.destroy()

        if not proceed:
            sys.exit(0)

        if existing_pid:
            kill_pid(existing_pid)

        # Give the old process a moment to release the port, then retry.
        for _ in range(20):
            lock_socket = acquire_single_instance_lock()
            if lock_socket:
                break
            time.sleep(0.25)

        if lock_socket is None:
            _root2 = tk.Tk()
            _root2.withdraw()
            messagebox.showerror(
                "Vertex OpenAI Proxy",
                "기존 실행 종료에 실패했습니다. 작업 관리자에서 직접 종료한 뒤 다시 실행해주세요.",
            )
            _root2.destroy()
            sys.exit(1)

    write_lock_pid()
    ProxyGuiApp(lock_socket=lock_socket).run()
