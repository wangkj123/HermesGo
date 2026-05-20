import pathlib
import subprocess
import sys

import requests


def get_github_token() -> str:
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        text=True,
        capture_output=True,
        check=True,
    )
    cred = {}
    for line in p.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            cred[k.strip()] = v.strip()
    return cred.get("password", "")


def main() -> int:
    token = get_github_token()
    if not token:
        print("ERROR: no GitHub token available from git credential helper")
        return 2

    owner = "wangkj123"
    repo = "HermesGo"
    api = f"https://api.github.com/repos/{owner}/{repo}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    dist_dir = pathlib.Path(__file__).resolve().parents[1] / "dist"
    artifacts = sorted(
        dist_dir.glob("*green*3ui*slim*.zip"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not artifacts:
        artifacts = sorted(
            dist_dir.glob("*slim*.zip"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    if not artifacts:
        print(f"ERROR: no slim zip found in {dist_dir}")
        return 3
    asset = artifacts[0]

    stable_asset_name = "HermesGo-green-3ui-slim.zip"
    tag = "v0.14.8-green-3ui-slim"
    release_name = "HermesGo v0.14.8 green 3-UI slim"
    body = """## HermesGo v0.14.8 green portable (CLI + Dashboard + WebUI + Desktop)

### Fixes in this build
- **EXE auto-update**: interactive launch always shows confirm dialog (立即更新 / 稍后); menu「更新」also confirms before download; not forced every launch
- **README version**: `Current release tag` stamped at build time (matches `hermes_cli` __version__)
- **Release asset**: stable download name `HermesGo-green-3ui-slim.zip` plus dated zip on GitHub
- **Chat scroll** (from v0.14.7): Desktop/WebUI bottom scroll stability; Kanban + portable isolation
- **Runtime version**: `hermes_cli` `__version__` = `0.14.8`
- Self-test: `run_full_smoke_iter.ps1` (all smokes passed)

### UIs
- **HermesGo.exe** / **HermesGo.bat** — Dashboard + WebUI; optional `--menu`; auto-update from this repo
- **Dashboard** — http://127.0.0.1:9119/env?quick=1
- **WebUI** — http://127.0.0.1:8787 (Kanban included)
- **Desktop** — `HermesDesktop.bat` (portable Electron)

### Package layout
- Root: `HermesGo.exe`, `README.txt` (EN/CN), three `.bat` launchers
- Under `app/`: `scripts/`, `runtime/`, `home/`, `assets/`, …

### Not included (~220 MB slim)
- Bundled Ollama runtime and preloaded model blobs

### Build from source
```powershell
powershell -File HermesGo/scripts/Compile-HermesGoBootstrap.ps1
powershell -File HermesGo/scripts/build_hermes_desktop_portable.ps1
py -3 HermesGo/build_zip_slim.py
py -3 scripts/publish_github_release.py
```
"""

    session = requests.Session()
    session.trust_env = False  # bypass broken system proxy for uploads.github.com

    r = session.get(f"{api}/releases/tags/{tag}", headers=headers, timeout=60)
    if r.status_code == 200:
        rel = r.json()
        rel_id = rel["id"]
        session.patch(
            f"{api}/releases/{rel_id}",
            headers=headers,
            json={"name": release_name, "body": body, "draft": False, "prerelease": False},
            timeout=60,
        ).raise_for_status()
    else:
        rr = session.post(
            f"{api}/releases",
            headers=headers,
            json={
                "tag_name": tag,
                "name": release_name,
                "body": body,
                "draft": False,
                "prerelease": False,
                "target_commitish": "main",
            },
            timeout=60,
        )
        rr.raise_for_status()
        rel_id = rr.json()["id"]

    rel = session.get(f"{api}/releases/{rel_id}", headers=headers, timeout=60).json()
    upload_names = [asset.name, stable_asset_name]
    for a in rel.get("assets", []):
        if a.get("name") in upload_names:
            session.delete(f"{api}/releases/assets/{a['id']}", headers=headers, timeout=60).raise_for_status()

    upload_url = rel["upload_url"].split("{", 1)[0]
    zip_bytes = asset.read_bytes()
    uploaded: list[str] = []
    for upload_name in upload_names:
        up = session.post(
            upload_url,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/zip",
                "Accept": "application/vnd.github+json",
            },
            params={"name": upload_name},
            data=zip_bytes,
            timeout=3600,
        )
        up.raise_for_status()
        uploaded.append(upload_name)
        print("uploaded", upload_name)

    final_rel = session.get(f"{api}/releases/{rel_id}", headers=headers, timeout=60).json()
    print("release_url=", final_rel.get("html_url"))
    for a in final_rel.get("assets", []):
        if a.get("name") in uploaded:
            print("asset_url=", a.get("browser_download_url"))
            print("asset_name=", a.get("name"))
            print("asset_size=", a.get("size"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
