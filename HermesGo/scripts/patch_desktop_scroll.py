"""Patch Hermes Desktop app.asar scroll pinning (MNt) for portable green builds."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]

# Dev tree: HermesGo/runtime/... ; slim zip / test tree: HermesGo/app/runtime/...
ASAR_CANDIDATES = (
    APP_ROOT / "runtime" / "hermes-desktop" / "resources" / "app.asar",
    APP_ROOT / "app" / "runtime" / "hermes-desktop" / "resources" / "app.asar",
)

EXTRACT = APP_ROOT / "logs" / "tmp" / "desktop-asar-patch"

# v4: no ResizeObserver/groupCount scrollTop restore; pinned follow via rAF + scrollToIndex.
NEW_MNT = (
    "function MNt({enabled:e,groupCount:t,scrollerRef:n,sessionKey:r,virtualizer:i})"
    "{let a=(0,P.useRef)(!1),o=(0,P.useRef)(0),s=(0,P.useRef)(r),"
    "f=(0,P.useRef)(!1),"
    "h=()=>{let e=n.current,t=document.getSelection();if(!e||!t||t.isCollapsed)return!1;"
    "let r=t.anchorNode;return!!r&&e.contains(r)},"
    "m=()=>{f.current=!0,a.current=!1},"
    "g=(0,P.useCallback)(()=>{let e=n.current;if(!e||!a.current||f.current||h())return;"
    "if(i&&typeof i.scrollToIndex==`function`){let t=Math.max(0,(i.options?.count??1)-1);"
    "i.scrollToIndex(t,{align:`end`}),o.current=e.scrollTop;return};"
    "let t=e.scrollHeight-e.scrollTop-e.clientHeight;if(t>kNt)return;"
    "e.scrollTop=e.scrollHeight,o.current=e.scrollTop},[n,i]),"
    "u=(0,P.useCallback)(()=>{f.current=!1,a.current=!0,"
    "requestAnimationFrame(()=>{a.current&&!f.current&&!h()&&g()})},[g]);"
    "(0,P.useEffect)(()=>()=>ENt(!1),[]),"
    "(0,P.useEffect)(()=>{let e=n.current;if(!e)return;e.style.overflowAnchor=`none`;"
    "let t=()=>{m()},r=()=>{h()?m():f.current=!1},l=()=>{"
    "if(f.current||h()){ENt(!0);return};"
    "let t=e.scrollTop,r=e.scrollHeight-(t+e.clientHeight);"
    "t<o.current-2&&(a.current=!1),o.current=t,ENt(r>kNt)},"
    "c=r=>{r.deltaY<0?t():r.deltaY>0&&e.scrollHeight-e.scrollTop-e.clientHeight<=kNt&&(a.current=!0)};"
    "return document.addEventListener(`selectionchange`,r),"
    "e.addEventListener(`pointerdown`,t,{passive:!0}),e.addEventListener(`mousedown`,t,{passive:!0}),"
    "e.addEventListener(`scroll`,l,{passive:!0}),e.addEventListener(`wheel`,c,{passive:!0}),"
    "e.addEventListener(`touchstart`,t,{passive:!0}),"
    "()=>{document.removeEventListener(`selectionchange`,r),"
    "e.removeEventListener(`pointerdown`,t),e.removeEventListener(`mousedown`,t),"
    "e.removeEventListener(`scroll`,l),e.removeEventListener(`wheel`,c),"
    "e.removeEventListener(`touchstart`,t)}},[n]),"
    "(0,P.useEffect)(()=>{if(!e||!a.current||f.current||h())return;"
    "let t=requestAnimationFrame(()=>{a.current&&!f.current&&!h()&&g()});"
    "return()=>cancelAnimationFrame(t)},[t,e,g]),"
    "(0,P.useEffect)(()=>{let t=s.current!==r;s.current=r,t&&(a.current=!1,f.current=!1)},[r,t]),"
    "I_e(`thread.runStart`,u)}"
)

MARKER = "cancelAnimationFrame(t)},[t,e,g])"


def _npx_cmd() -> list[str]:
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    if not npx:
        raise FileNotFoundError("npx not found on PATH")
    return [npx, "--yes", "@electron/asar"]


def _apply(text: str) -> str:
    text = text.replace("var DNt=220,ONt=4,kNt=120;", "var DNt=220,ONt=4,kNt=48;")
    text = text.replace("var DNt=220,ONt=4,kNt=280;", "var DNt=220,ONt=4,kNt=48;")
    if MARKER in text and "scrollToIndex(t,{align:`end`})" in text:
        return text
    start = text.find("function MNt({enabled:e")
    if start < 0:
        raise ValueError("MNt not found")
    end = text.find("I_e(`thread.runStart`,u)}", start)
    if end < 0:
        raise ValueError("MNt end marker not found")
    end += len("I_e(`thread.runStart`,u)}")
    return text[:start] + NEW_MNT + text[end:]


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
    js = next((work / "dist" / "assets").glob("index-*.js"))
    js.write_text(_apply(js.read_text(encoding="utf-8")), encoding="utf-8")
    subprocess.run(
        _npx_cmd() + ["pack", str(work), str(asar)],
        check=True,
        shell=os.name == "nt",
    )
    shutil.rmtree(work, ignore_errors=True)
    print(f"patched {asar}")
    return True


def main() -> int:
    extra = [Path(p) for p in sys.argv[1:]]
    targets = list(ASAR_CANDIDATES) + extra
    patched = 0
    for asar in targets:
        if patch_asar(asar):
            patched += 1
    if patched == 0:
        print("no app.asar found under runtime/ or app/runtime/", file=sys.stderr)
        return 1
    if EXTRACT.exists():
        shutil.rmtree(EXTRACT, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
