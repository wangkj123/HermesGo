"""Patch Hermes Desktop app.asar so embedded shells inherit portable app/home secrets."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]

ASAR_CANDIDATES = (
    APP_ROOT / "runtime" / "hermes-desktop" / "resources" / "app.asar",
    APP_ROOT / "app" / "runtime" / "hermes-desktop" / "resources" / "app.asar",
)

EXTRACT = APP_ROOT / "logs" / "tmp" / "desktop-asar-shell-patch"

HELPER = r"""
// --- HermesGo portable shell env (patched) ---
const PORTABLE_CREDENTIAL_SUFFIXES = ['_API_KEY', '_TOKEN', '_SECRET', '_KEY', '_BASE_URL']

function mergePortableCredentialsIntoShellEnv(baseEnv) {
  const env = { ...baseEnv }
  const portableRoot = env.HERMES_PORTABLE_APP_ROOT
    ? path.resolve(String(env.HERMES_PORTABLE_APP_ROOT))
    : null
  if (portableRoot) {
    env.HERMES_PORTABLE_APP_ROOT = portableRoot
    if (!env.HERMES_HOME) {
      env.HERMES_HOME = path.join(portableRoot, 'home')
    }
    const binDir = path.join(portableRoot, 'runtime', 'bin')
    if (directoryExists(binDir)) {
      const parts = String(env.PATH || '')
        .split(path.delimiter)
        .map(p => p.trim())
        .filter(Boolean)
      if (!parts.some(p => path.resolve(p) === binDir)) {
        env.PATH = [binDir, ...parts].join(path.delimiter)
      }
    }
    env.HERMESGO_STRICT_PORTABLE = env.HERMESGO_STRICT_PORTABLE || '1'
    env.HERMES_PORTABLE_STRICT = env.HERMES_PORTABLE_STRICT || '1'
    env.HERMES_DISABLE_WSL = env.HERMES_DISABLE_WSL || '1'
  }
  const home = env.HERMES_HOME ? path.resolve(String(env.HERMES_HOME)) : null
  if (!home) {
    return env
  }
  env.HERMES_HOME = home
  const dotenvPath = path.join(home, '.env')
  try {
    if (!fs.existsSync(dotenvPath)) {
      return env
    }
    const text = fs.readFileSync(dotenvPath, 'utf8')
    for (const rawLine of text.split(/\r?\n/)) {
      const line = rawLine.trim()
      if (!line || line.startsWith('#')) {
        continue
      }
      const eq = line.indexOf('=')
      if (eq < 1) {
        continue
      }
      const key = line.slice(0, eq).trim()
      let val = line.slice(eq + 1).trim()
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1)
      }
      if (!key || !val) {
        continue
      }
      if (PORTABLE_CREDENTIAL_SUFFIXES.some(suffix => key.endsWith(suffix))) {
        env[key] = val
      }
    }
  } catch {
    // Best-effort — shell must still start if .env is temporarily locked.
  }
  return env
}
"""

RESOLVE_OLD = """function resolveHermesHome() {
  if (process.env.HERMES_HOME) return path.resolve(process.env.HERMES_HOME)
  if (USER_DATA_OVERRIDE) return path.join(path.resolve(USER_DATA_OVERRIDE), 'hermes-home')"""

RESOLVE_NEW = """function resolveHermesHome() {
  if (process.env.HERMES_HOME) return path.resolve(process.env.HERMES_HOME)
  if (process.env.HERMES_PORTABLE_APP_ROOT) {
    return path.join(path.resolve(process.env.HERMES_PORTABLE_APP_ROOT), 'home')
  }
  if (USER_DATA_OVERRIDE) return path.join(path.resolve(USER_DATA_OVERRIDE), 'hermes-home')"""

TERMINAL_ENV_OLD = """  env.TERM_PROGRAM_VERSION = app.getVersion()

  return env
}

function terminalChannel(id, suffix) {"""

WIN_SHELL_OLD = """function terminalShellCommand() {
  if (IS_WINDOWS) {
    return { args: [], command: process.env.COMSPEC || 'cmd.exe' }
  }"""

WIN_SHELL_NEW = """function terminalShellCommand() {
  if (IS_WINDOWS) {
    const init = process.env.HERMES_HOME
      ? path.join(path.resolve(process.env.HERMES_HOME), 'portable-shell-init.cmd')
      : null
    if (init && fs.existsSync(init)) {
      const comspec = process.env.COMSPEC || 'cmd.exe'
      return {
        args: ['/Q', '/K', init],
        command: comspec,
        name: 'Windows Shell'
      }
    }
    return { args: [], command: process.env.COMSPEC || 'cmd.exe', name: 'Windows Shell' }
  }"""

TERMINAL_ENV_NEW = """  env.TERM_PROGRAM_VERSION = app.getVersion()

  return mergePortableCredentialsIntoShellEnv(env)
}

function terminalChannel(id, suffix) {"""


def _npx_cmd() -> list[str]:
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    if not npx:
        raise FileNotFoundError("npx not found on PATH")
    return [npx, "--yes", "@electron/asar"]


def _apply_main(text: str) -> str:
    if "mergePortableCredentialsIntoShellEnv" in text:
        return text
    if RESOLVE_OLD not in text:
        raise ValueError("resolveHermesHome block not found")
    if TERMINAL_ENV_OLD not in text:
        raise ValueError("terminalShellEnv return block not found")
    if WIN_SHELL_OLD not in text:
        raise ValueError("terminalShellCommand Windows block not found")
    text = text.replace(RESOLVE_OLD, RESOLVE_NEW, 1)
    insert_at = text.find("function terminalShellCommand()")
    if insert_at < 0:
        raise ValueError("terminalShellCommand not found")
    text = text[:insert_at] + HELPER + "\n" + text[insert_at:]
    text = text.replace(WIN_SHELL_OLD, WIN_SHELL_NEW, 1)
    text = text.replace(TERMINAL_ENV_OLD, TERMINAL_ENV_NEW, 1)
    return text


def patch_asar(asar: Path) -> bool:
    if not asar.is_file():
        return False
    work = EXTRACT / asar.stem
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        _npx_cmd() + ["extract", str(asar), str(work)],
        check=True,
        shell=os.name == "nt",
    )
    main_cjs = work / "electron" / "main.cjs"
    main_cjs.write_text(_apply_main(main_cjs.read_text(encoding="utf-8")), encoding="utf-8")
    subprocess.run(
        _npx_cmd() + ["pack", str(work), str(asar)],
        check=True,
        shell=os.name == "nt",
    )
    shutil.rmtree(work, ignore_errors=True)
    print(f"patched portable shell env: {asar}")
    return True


def main() -> int:
    extra = [Path(p) for p in sys.argv[1:]]
    targets = list(ASAR_CANDIDATES) + extra
    patched = 0
    for asar in targets:
        if patch_asar(asar):
            patched += 1
    if patched == 0:
        print("no app.asar found", file=sys.stderr)
        return 1
    if EXTRACT.exists():
        shutil.rmtree(EXTRACT, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
