"""Start HermesGo dashboard from E:\hermes-test"""
import subprocess, time, urllib.request, sys, os

PYTHON = r"E:\hermes-test\runtime\python311\python.exe"
CWD = r"E:\hermes-test\runtime\hermes-agent"

# Kill existing
subprocess.run(
    [
        "taskkill", "/F", "/IM", "python.exe",
        "/FI", "WINDOWTITLE eq Hermes*",
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
time.sleep(2)

# Start dashboard
p = subprocess.Popen(
    [PYTHON, "-m", "hermes_cli.main", "dashboard",
     "--host", "127.0.0.1", "--port", "9119", "--no-open"],
    cwd=CWD,
    creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0
)
print(f"Dashboard PID: {p.pid}")

# Wait and test
for i in range(10):
    time.sleep(2)
    try:
        r = urllib.request.urlopen('http://127.0.0.1:9119/', timeout=3)
        html = r.read().decode()
        print(f"✅ Dashboard responding (attempt {i+1})")
        print(html[:300])
        # Also test WebUI
        try:
            r2 = urllib.request.urlopen('http://127.0.0.1:8787/', timeout=3)
            print(f"✅ WebUI also responding")
        except:
            print("WebUI not yet running on 8787")
        sys.exit(0)
    except Exception as e:
        print(f"  Attempt {i+1}: {e}")

print("❌ Dashboard failed to start")
