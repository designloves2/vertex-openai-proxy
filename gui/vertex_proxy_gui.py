#!/usr/bin/env python3
"""
Vertex OpenAI Proxy - tray-based control panel (pywebview edition).

Starts/stops/restarts the Node.js proxy server, edits .env (project id,
location, model, port), and minimizes to the Windows system tray instead
of leaving a console window open. The UI is plain HTML/CSS/JS
(gui/index.html) rendered by the OS's native web view (WebView2 on
Windows); this file is only the backend/bridge.

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
import traceback
import tkinter as tk
import urllib.request
from tkinter import messagebox

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GUI_DIR = os.path.dirname(os.path.abspath(__file__))
CRASH_LOG_PATH = os.path.join(GUI_DIR, "crash.log")


def log_crash(exc_type, exc_value, exc_tb):
    """pythonw.exe has no console, so an unhandled exception normally just
    kills the process with zero visible output. Write it to a file instead."""
    try:
        with open(CRASH_LOG_PATH, "a", encoding="utf-8") as f:
            f.write("\n" + "=" * 70 + "\n")
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "\n")
            traceback.print_exception(exc_type, exc_value, exc_tb, file=f)
    except Exception:
        pass


sys.excepthook = log_crash

try:
    import webview
except Exception:
    log_crash(*sys.exc_info())
    _root = tk.Tk()
    _root.withdraw()
    messagebox.showerror(
        "Vertex OpenAI Proxy",
        "pywebview를 불러오지 못해 GUI를 시작할 수 없습니다.\n\n"
        "PowerShell에서 다음을 실행해 설치해주세요:\n"
        "  python -m pip install -r gui\\requirements.txt\n\n"
        f"자세한 오류는 {CRASH_LOG_PATH} 파일을 확인하세요.",
    )
    _root.destroy()
    sys.exit(1)

try:
    import pystray
    from PIL import Image, ImageDraw
except ImportError:
    pystray = None
    Image = None
    ImageDraw = None

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
                        continue
                    lines.append(f"{key}={values[key]}")
                    seen.add(key)
                else:
                    lines.append(stripped)
    for key in ENV_KEYS:
        if key not in seen:
            lines.append(f"{key}={values[key]}")
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
# Backend bridge exposed to the HTML/JS front-end as `pywebview.api`
# ---------------------------------------------------------------------------
class Api:
    def __init__(self):
        self.window = None
        self.proc = None
        self.tray_icon = None
        self.lock_socket = None

    # -- env --
    def get_env(self):
        return read_env()

    def _validate_and_write(self, values):
        if not values.get("GOOGLE_CLOUD_PROJECT_ID", "").strip():
            return {"ok": False, "error": "Project ID를 입력해주세요."}
        write_env(values)
        self._log("[GUI] .env를 저장했습니다.\n")
        return {"ok": True}

    def models(self, port):
        return fetch_live_models(port or "3000")

    # -- log / status --
    def _log(self, line):
        if self.window:
            try:
                self.window.evaluate_js(f"appendLog({json.dumps(line)})")
            except Exception:
                pass

    def _set_status(self, running):
        if self.window:
            try:
                self.window.evaluate_js(f"setStatus({'true' if running else 'false'})")
            except Exception:
                pass

    def status(self):
        return {"running": bool(self.proc and self.proc.poll() is None)}

    # -- server process control --
    def start(self, fields=None):
        if self.proc and self.proc.poll() is None:
            self._log("[GUI] 이미 실행 중입니다.\n")
            return {"ok": True}

        if fields:
            current = read_env()
            if current != fields:
                result = self._validate_and_write(fields)
                if not result["ok"]:
                    return result

        node_path = shutil.which("node")
        if not node_path:
            return {"ok": False, "error": "node 실행 파일을 찾을 수 없습니다. Node.js가 설치되어 있는지 확인해주세요."}

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
            return {"ok": False, "error": f"서버 시작 실패: {exc}"}

        self._set_status(True)
        self._log("[GUI] 서버를 시작했습니다.\n")
        threading.Thread(target=self._read_process_output, daemon=True).start()
        return {"ok": True}

    def _read_process_output(self):
        proc = self.proc
        if not proc or not proc.stdout:
            return
        for line in iter(proc.stdout.readline, ""):
            self._log(line)
        proc.stdout.close()
        self._set_status(False)
        self._log("[GUI] 서버 프로세스가 종료되었습니다.\n")

    def stop(self):
        if not self.proc or self.proc.poll() is not None:
            self._log("[GUI] 실행 중인 서버가 없습니다.\n")
            self._set_status(False)
            return {"ok": True}
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self._set_status(False)
        self._log("[GUI] 서버를 정지했습니다.\n")
        return {"ok": True}

    def restart(self, fields=None):
        self.stop()
        time.sleep(0.3)
        return self.start(fields)

    def save_and_restart(self, fields):
        result = self._validate_and_write(fields or {})
        if not result["ok"]:
            return result
        return self.restart(fields)

    # -- tray / lifecycle --
    def hide_to_tray(self):
        if self.window:
            self.window.hide()
        if pystray is None:
            _root = tk.Tk()
            _root.withdraw()
            messagebox.showinfo(
                "트레이 사용 불가",
                "pystray/Pillow가 설치되어 있지 않아 트레이로 내려갈 수 없습니다.\n"
                "'pip install -r gui/requirements.txt'를 실행해주세요.",
            )
            _root.destroy()
            return
        if self.tray_icon is None:
            image = self._make_tray_image()
            menu = pystray.Menu(
                pystray.MenuItem("열기", self._show_from_tray, default=True),
                pystray.MenuItem("서버 재시작", lambda: self.restart()),
                pystray.MenuItem("GUI 재시작 (프로세스 재시작)", self._restart_app_from_tray),
                pystray.MenuItem("완전히 종료", self._quit_from_tray),
            )
            self.tray_icon = pystray.Icon("vertex-openai-proxy", image, "Vertex OpenAI Proxy", menu)
            threading.Thread(target=self.tray_icon.run, daemon=True).start()

    def _make_tray_image(self):
        if Image is None:
            return None
        size = 64
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=16, fill=(26, 26, 26, 255))
        draw.text((size / 2 - 8, size / 2 - 14), "V", fill=(255, 255, 255, 255))
        return img

    def _show_from_tray(self, _icon=None, _item=None):
        if self.window:
            self.window.show()

    def _quit_from_tray(self, _icon=None, _item=None):
        self._shutdown(relaunch=False)

    def _restart_app_from_tray(self, _icon=None, _item=None):
        self._shutdown(relaunch=True)

    def _shutdown(self, relaunch):
        """Tears down the app and (optionally) relaunches a fresh process.
        A watchdog timer guarantees the process dies even if webview/tray
        teardown hangs for any reason."""
        threading.Timer(1.5, lambda: os._exit(0)).start()

        try:
            self.stop()
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
            if self.window:
                self.window.destroy()
        except Exception:
            pass


def main(lock_socket):
    api = Api()
    api.lock_socket = lock_socket

    index_path = os.path.join(GUI_DIR, "index.html")
    window = webview.create_window(
        "Vertex OpenAI Proxy",
        index_path,
        js_api=api,
        width=760,
        height=640,
        min_size=(680, 420),
        background_color="#F1E3D3",
    )
    api.window = window

    def on_closing():
        api.hide_to_tray()
        return False  # cancel the actual close; we just hid the window

    window.events.closing += on_closing

    webview.start(debug=False)


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
    try:
        main(lock_socket)
    except Exception:
        log_crash(*sys.exc_info())
        try:
            _root3 = tk.Tk()
            _root3.withdraw()
            messagebox.showerror(
                "Vertex OpenAI Proxy",
                f"GUI 실행 중 오류가 발생했습니다.\n자세한 내용은 {CRASH_LOG_PATH} 파일을 확인하세요.",
            )
            _root3.destroy()
        except Exception:
            pass
        raise
