#!/usr/bin/env python3
"""
Vertex OpenAI Proxy - tray-based control panel.

Starts/stops/restarts the Node.js proxy server, edits .env (project id,
location, model, port), and minimizes to the Windows system tray instead
of leaving a console window open.

Run with: pythonw vertex_proxy_gui.py   (no console window)
      or: python  vertex_proxy_gui.py   (for debugging, shows console)
"""
import io
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import tkinter as tk
import urllib.request
import json
from tkinter import ttk, messagebox

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


def acquire_single_instance_lock():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", SINGLE_INSTANCE_PORT))
        s.listen(1)
        return s
    except OSError:
        s.close()
        return None


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
# Flat rounded button (plain tk.Canvas, no shadows)
# ---------------------------------------------------------------------------
class RoundedButton(tk.Canvas):
    def __init__(self, parent, text, command, width=120, height=36, radius=14,
                 bg=BLACK, hover=BLACK_HOVER, fg=WHITE, font_size=10):
        super().__init__(parent, width=width, height=height, bg=parent["bg"],
                          highlightthickness=0, bd=0)
        self.command = command
        self.bg_color = bg
        self.hover_color = hover
        self.width = width
        self.height = height
        self.radius = radius
        self._shape = self._round_rect(2, 2, width - 2, height - 2, radius, fill=bg, outline=bg)
        self._label = self.create_text(width / 2, height / 2, text=text, fill=fg,
                                        font=(FONT_NAME, font_size, "bold"))
        self.bind("<Button-1>", self._on_click)
        self.bind("<Enter>", lambda e: self.itemconfig(self._shape, fill=self.hover_color, outline=self.hover_color))
        self.bind("<Leave>", lambda e: self.itemconfig(self._shape, fill=self.bg_color, outline=self.bg_color))

    def _round_rect(self, x1, y1, x2, y2, r, **kwargs):
        points = [
            x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
            x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
        ]
        return self.create_polygon(points, smooth=True, **kwargs)

    def _on_click(self, _event):
        if self.command:
            self.command()

    def set_enabled(self, enabled):
        state_color = self.bg_color if enabled else "#8A8A8A"
        self.itemconfig(self._shape, fill=state_color, outline=state_color)
        self.command_enabled = enabled

    def set_text(self, text):
        self.itemconfig(self._label, text=text)


def _round_rect_points(x1, y1, x2, y2, r):
    return [
        x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
        x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
    ]


class RoundedEntry(tk.Canvas):
    """A flat, rounded-corner text entry: a rounded rect drawn on a Canvas
    with a borderless tk.Entry inset on top of it (same fill color, so the
    entry blends in and only the canvas corners show as rounded)."""

    def __init__(self, parent, width=300, height=36, radius=14, bg=BLACK, fg=WHITE, font_size=10):
        super().__init__(parent, width=width, height=height, bg=parent["bg"], highlightthickness=0, bd=0)
        self.create_polygon(_round_rect_points(2, 2, width - 2, height - 2, radius),
                             smooth=True, fill=bg, outline=bg)
        self.entry = tk.Entry(self, bg=bg, fg=fg, insertbackground=fg, relief="flat",
                               bd=0, highlightthickness=0, font=(FONT_NAME, font_size))
        inner_width = max(width - radius * 2, 10)
        self.create_window(radius, height // 2, window=self.entry, anchor="w",
                            width=inner_width, height=height - 12)

    def get(self):
        return self.entry.get()

    def insert(self, index, text):
        return self.entry.insert(index, text)

    def delete(self, first, last=None):
        return self.entry.delete(first, last)

    def set_masked(self, masked):
        self.entry.configure(show="•" if masked else "")


class RoundedCombo(tk.Canvas):
    """Same rounded-rect trick as RoundedEntry, hosting a ttk.Combobox."""

    _style_ready = False

    def __init__(self, parent, values, width=300, height=36, radius=14, bg=BLACK, fg=WHITE, font_size=10):
        super().__init__(parent, width=width, height=height, bg=parent["bg"], highlightthickness=0, bd=0)
        self.create_polygon(_round_rect_points(2, 2, width - 2, height - 2, radius),
                             smooth=True, fill=bg, outline=bg)

        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Rounded.TCombobox", fieldbackground=bg, background=bg,
                         foreground=fg, arrowcolor=fg, borderwidth=0, relief="flat")
        style.map("Rounded.TCombobox", fieldbackground=[("readonly", bg)])
        root = parent.winfo_toplevel()
        root.option_add("*TCombobox*Listbox.background", bg)
        root.option_add("*TCombobox*Listbox.foreground", fg)
        root.option_add("*TCombobox*Listbox.selectBackground", BLACK_HOVER)
        root.option_add("*TCombobox*Listbox.selectForeground", fg)

        self.combo = ttk.Combobox(self, values=values, style="Rounded.TCombobox", font=(FONT_NAME, font_size))
        inner_width = max(width - radius * 2, 10)
        self.create_window(radius, height // 2, window=self.combo, anchor="w",
                            width=inner_width, height=height - 12)

    def get(self):
        return self.combo.get()

    def set(self, value):
        return self.combo.set(value)

    def set_values(self, values):
        self.combo["values"] = values


# ---------------------------------------------------------------------------
# Main app
# ---------------------------------------------------------------------------
class ProxyGuiApp:
    def __init__(self, lock_socket=None):
        self.lock_socket = lock_socket
        self.root = tk.Tk()
        self.root.title("Vertex OpenAI Proxy")
        self.root.configure(bg=BEIGE)
        self.root.protocol("WM_DELETE_WINDOW", self.hide_to_tray)
        self.root.bind("<Unmap>", self._on_unmap)

        self.proc = None
        self.log_queue = queue.Queue()
        self.tray_icon = None

        self._build_ui()
        self._load_env_into_fields()

        # Size the window to fit its content exactly (no leftover margin),
        # instead of an arbitrary fixed geometry.
        self.root.update_idletasks()
        width = self.root.winfo_reqwidth()
        height = self.root.winfo_reqheight()
        self.root.geometry(f"{width}x{height}")
        self.root.minsize(width, 360)

        self.root.after(100, self._poll_log_queue)

    # -- UI ----------------------------------------------------------------
    def _build_ui(self):
        pad = {"padx": 16, "pady": 6}

        header = tk.Label(self.root, text="Vertex OpenAI Proxy", bg=BEIGE, fg=BLACK,
                           font=(FONT_NAME, 18, "bold"))
        header.pack(anchor="w", padx=16, pady=(16, 4))

        self.status_canvas = tk.Canvas(self.root, width=14, height=14, bg=BEIGE, highlightthickness=0)
        self.status_dot = self.status_canvas.create_oval(2, 2, 12, 12, fill="#B23B3B", outline="")
        status_row = tk.Frame(self.root, bg=BEIGE)
        status_row.pack(anchor="w", padx=16, pady=(0, 12))
        self.status_canvas.pack(in_=status_row, side="left")
        self.status_label = tk.Label(status_row, text="중지됨", bg=BEIGE, fg=BLACK, font=(FONT_NAME, 10, "bold"))
        self.status_label.pack(side="left", padx=(8, 0))

        form = tk.Frame(self.root, bg=BEIGE)
        form.pack(fill="x", padx=16)

        self.entry_project = self._add_field(form, "Google Cloud Project ID", maskable=True)
        self.entry_location = self._add_field(form, "리전 (Location)")
        self.combo_model = self._add_model_field(form, "Gemini 모델")
        self.entry_port = self._add_field(form, "포트 (Port)")

        btn_row = tk.Frame(self.root, bg=BEIGE)
        btn_row.pack(fill="x", padx=16, pady=(14, 8))

        self.btn_start = RoundedButton(btn_row, "시작", self.start_server, width=90)
        self.btn_stop = RoundedButton(btn_row, "정지", self.stop_server, width=90)
        self.btn_restart = RoundedButton(btn_row, "재시작", self.restart_server, width=90)
        self.btn_save = RoundedButton(btn_row, "저장 후 재시작", self.save_and_restart, width=150)

        for b in (self.btn_start, self.btn_stop, self.btn_restart, self.btn_save):
            b.pack(side="left", padx=(0, 10))

        tray_hint = tk.Label(self.root, text="창을 닫으면 트레이로 최소화됩니다. 완전히 종료하려면 트레이 아이콘 메뉴를 사용하세요.",
                              bg=BEIGE, fg="#5A4E42", font=(FONT_NAME, 8))
        tray_hint.pack(anchor="w", padx=16, pady=(0, 8))

        # -- log (collapsible / accordion) --
        log_header = tk.Frame(self.root, bg=BEIGE)
        log_header.pack(fill="x", padx=16)
        self.log_toggle_label = tk.Label(log_header, text="▼  로그", bg=BEIGE, fg=BLACK,
                                          font=(FONT_NAME, 9, "bold"), cursor="hand2")
        self.log_toggle_label.pack(side="left")
        self.log_toggle_label.bind("<Button-1>", lambda e: self._toggle_log())

        self.log_visible = True
        self.log_frame = tk.Frame(self.root, bg=BLACK)
        self.log_frame.pack(fill="both", expand=True, padx=16, pady=(4, 16))
        self.log_text = tk.Text(self.log_frame, bg=BLACK, fg=WHITE, insertbackground=WHITE,
                                 relief="flat", bd=0, font=("Consolas", 9), wrap="word", height=12)
        self.log_text.pack(fill="both", expand=True, padx=1, pady=1)
        self.log_text.configure(state="disabled")

    def _toggle_log(self):
        self.log_visible = not self.log_visible
        if self.log_visible:
            self.log_frame.pack(fill="both", expand=True, padx=16, pady=(4, 16))
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
        row = tk.Frame(parent, bg=BEIGE)
        row.pack(fill="x", pady=4)
        tk.Label(row, text=label_text, bg=BEIGE, fg=BLACK, font=(FONT_NAME, 9, "bold"),
                 width=24, anchor="w").pack(side="left")
        entry_width = 440 - 42 if maskable else 440
        entry = RoundedEntry(row, width=entry_width, height=36)
        entry.pack(side="left")
        if maskable:
            entry._masked = True
            entry.set_masked(True)
            toggle = RoundedButton(row, "\U0001F441", lambda: self._toggle_mask(entry, toggle),
                                    width=36, height=36, radius=12, font_size=12)
            toggle.pack(side="left", padx=(6, 0))
        return entry

    def _toggle_mask(self, entry, toggle_button):
        masked = not getattr(entry, "_masked", True)
        entry._masked = masked
        entry.set_masked(masked)
        toggle_button.set_text("\U0001F441" if masked else "\U0001F576")

    def _add_model_field(self, parent, label_text):
        row = tk.Frame(parent, bg=BEIGE)
        row.pack(fill="x", pady=4)
        tk.Label(row, text=label_text, bg=BEIGE, fg=BLACK, font=(FONT_NAME, 9, "bold"),
                 width=24, anchor="w").pack(side="left")
        combo = RoundedCombo(row, values=FALLBACK_MODELS, width=440, height=36)
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
        self.combo_model.set_values(merged)

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
        self.status_canvas.itemconfig(self.status_dot, fill=color)
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
        if self.tray_icon:
            self.tray_icon.stop()
        self.root.after(0, self._quit)

    def _quit(self):
        self.stop_server()
        self.root.destroy()

    def _restart_app_from_tray(self, _icon=None, _item=None):
        if self.tray_icon:
            self.tray_icon.stop()
        self.root.after(0, self._restart_app)

    def _restart_app(self):
        """Fully exit this GUI process and launch a brand new one (not just
        the Node server) — for when the GUI itself needs a clean restart."""
        self.stop_server()
        if self.lock_socket:
            self.lock_socket.close()
        try:
            subprocess.Popen([sys.executable, os.path.abspath(__file__)], cwd=PROJECT_ROOT)
        except Exception as exc:
            messagebox.showerror("오류", f"GUI 재시작 실패: {exc}")
        self.root.destroy()
        sys.exit(0)

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    lock_socket = acquire_single_instance_lock()
    if lock_socket is None:
        _root = tk.Tk()
        _root.withdraw()
        messagebox.showinfo("Vertex OpenAI Proxy", "이미 실행 중입니다. 시스템 트레이를 확인하세요.")
        _root.destroy()
        sys.exit(0)
    ProxyGuiApp(lock_socket=lock_socket).run()
