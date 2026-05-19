import zipfile, os, datetime

old_zip = "/mnt/e/AI/hermes/HermesGo-2026.05.08-DeepSeek-v13.zip"
new_zip = "/mnt/e/AI/hermes/HermesGo-2026.05.10-DeepSeek-v13-WebUI.zip"

# Source directories
script_dir = "/mnt/e/AI/hermes/HermesGo"
webui_dir = "/mnt/e/AI/hermes/hermes-webui"

# Files to replace with updated versions
UPDATES = {
    "HermesGo/app/scripts/Start-HermesGo.ps1": os.path.join(script_dir, "Start-HermesGo.ps1"),
    "HermesGo/app/runtime/hermes-agent/hermes_cli/web_server.py": os.path.join(script_dir, "hermes_cli", "web_server.py"),
}

with zipfile.ZipFile(old_zip, "r") as zin:
    with zipfile.ZipFile(new_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=5) as zout:
        updated_names = set()
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename in UPDATES:
                data = open(UPDATES[item.filename], "rb").read()
                updated_names.add(item.filename)
            elif "web_dist/" in item.filename and not item.is_dir():
                base = item.filename.split("web_dist/")[-1]
                new_path = os.path.join(script_dir, "hermes_cli", "web_dist", base)
                if os.path.exists(new_path):
                    data = open(new_path, "rb").read()
            zout.writestr(item, data)

        # Add HermesWebUI.bat
        bat_path = os.path.join(script_dir, "HermesWebUI.bat")
        with open(bat_path, "rb") as f:
            info = zipfile.ZipInfo("HermesGo/HermesWebUI.bat")
            info.date_time = datetime.datetime.now().timetuple()[:6]
            zout.writestr(info, f.read())

        # Add hermes-webui from clone (excluding .git, __pycache__, test_*)
        webui_count = 0
        for root, dirs, files in os.walk(webui_dir):
            for fname in files:
                if fname.startswith("test_") or ".git" in root or "__pycache__" in root:
                    continue
                fpath = os.path.join(root, fname)
                rel = os.path.relpath(fpath, webui_dir).replace("\\", "/")
                arcname = "HermesGo/app/runtime/hermes-webui/" + rel
                info = zipfile.ZipInfo(arcname)
                info.date_time = datetime.datetime.now().timetuple()[:6]
                with open(fpath, "rb") as f:
                    zout.writestr(info, f.read())
                webui_count += 1

        for name in sorted(updated_names):
            print(f"  UPDATED: {name}")
        print(f"  ADDED: HermesGo/HermesWebUI.bat")
        print(f"  WebUI files: {webui_count}")

size_mb = os.path.getsize(new_zip) / 1024 / 1024
print(f"Created: {new_zip} ({size_mb:.1f} MB)")
