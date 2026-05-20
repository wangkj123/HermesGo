"""Patch Hermes Desktop app.asar scroll pinning (MNt) for portable green builds."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]
ASAR = APP_ROOT / "runtime" / "hermes-desktop" / "resources" / "app.asar"
EXTRACT = APP_ROOT / "logs" / "tmp" / "desktop-asar-patch"

# v3: default unpinned; no auto re-pin on layout; preserve scroll only when NOT at bottom.
NEW_MNT = (
    "function MNt({enabled:e,groupCount:t,scrollerRef:n,sessionKey:r,virtualizer:i})"
    "{let a=(0,P.useRef)(!1),o=(0,P.useRef)(0),s=(0,P.useRef)(r),c=(0,P.useRef)(0),"
    "f=(0,P.useRef)(!1),p=(0,P.useRef)(null),"
    "h=()=>{let e=n.current,t=document.getSelection();if(!e||!t||t.isCollapsed)return!1;"
    "let r=t.anchorNode;return!!r&&e.contains(r)},"
    "m=()=>{f.current=!0,a.current=!1},"
    "g=(0,P.useCallback)(()=>{let e=n.current;if(!e||!a.current||f.current||h())return;"
    "let t=e.scrollHeight-e.scrollTop-e.clientHeight;if(t>kNt)return;"
    "e.scrollTop=e.scrollHeight,o.current=e.scrollTop},[n]),"
    "u=(0,P.useCallback)(()=>{f.current=!1,a.current=!0,"
    "requestAnimationFrame(()=>{a.current&&!f.current&&!h()&&g()})},[g]);"
    "(0,P.useEffect)(()=>()=>ENt(!1),[]),"
    "(0,P.useEffect)(()=>{let e=n.current;if(!e)return;e.style.overflowAnchor=`none`;"
    "let t=()=>{m()},r=()=>{h()?m():f.current=!1},i=()=>{"
    "if(f.current||h()){ENt(!0);return};"
    "let r=e.scrollTop,t=e.scrollHeight-(r+e.clientHeight);"
    "r<o.current-2&&(a.current=!1),o.current=r,ENt(t>kNt)},"
    "l=r=>{r.deltaY<0?t():r.deltaY>0&&e.scrollHeight-e.scrollTop-e.clientHeight<=kNt&&(a.current=!0)};"
    "return document.addEventListener(`selectionchange`,r),"
    "e.addEventListener(`pointerdown`,t,{passive:!0}),e.addEventListener(`mousedown`,t,{passive:!0}),"
    "e.addEventListener(`scroll`,i,{passive:!0}),e.addEventListener(`wheel`,l,{passive:!0}),"
    "e.addEventListener(`touchstart`,t,{passive:!0}),"
    "()=>{document.removeEventListener(`selectionchange`,r),"
    "e.removeEventListener(`pointerdown`,t),e.removeEventListener(`mousedown`,t),"
    "e.removeEventListener(`scroll`,i),e.removeEventListener(`wheel`,l),"
    "e.removeEventListener(`touchstart`,t)}},[n]),"
    "(0,P.useEffect)(()=>{if(!e)return;let t=n.current;if(!t)return;let r=null,"
    "i=new ResizeObserver(()=>{if(f.current||h()||!a.current)return;"
    "r!==null&&cancelAnimationFrame(r),r=requestAnimationFrame(()=>{r=null,a.current&&!f.current&&!h()&&g()})});"
    "return i.observe(t),t.firstElementChild&&r.observe(t.firstElementChild),"
    "()=>{r!==null&&cancelAnimationFrame(r),i.disconnect()}},[e,g,n]),"
    "(0,P.useEffect)(()=>{if(!e)return;let i=n.current;if(!i||a.current||f.current||h())return;"
    "let r=i.scrollHeight-i.scrollTop-i.clientHeight;if(r<=kNt)return;"
    "let l=i.scrollTop;p.current=l,requestAnimationFrame(()=>{requestAnimationFrame(()=>{"
    "if(!i||a.current||f.current||h())return;"
    "let e=i.scrollHeight-i.scrollTop-i.clientHeight;if(e<=kNt)return;"
    "let t=p.current;t!=null&&Math.abs(i.scrollTop-t)>3&&(i.scrollTop=t,o.current=t)})})},[t,e]),"
    "(0,P.useEffect)(()=>{let t=s.current!==r;s.current=r,c.current=t,t&&(a.current=!1,f.current=!1)},[r,t]),"
    "I_e(`thread.runStart`,u)}"
)

MARKER = "p.current=l,requestAnimationFrame"


def _npx_cmd() -> list[str]:
    npx = shutil.which("npx") or shutil.which("npx.cmd")
    if not npx:
        raise FileNotFoundError("npx not found on PATH")
    return [npx, "--yes", "@electron/asar"]


def _apply(text: str) -> str:
    text = text.replace("var DNt=220,ONt=4,kNt=120;", "var DNt=220,ONt=4,kNt=48;")
    text = text.replace("var DNt=220,ONt=4,kNt=280;", "var DNt=220,ONt=4,kNt=48;")
    if MARKER in text and NEW_MNT[:60] in text:
        return text
    # Replace any prior MNt implementation up to I_e(`thread.runStart`,u)}
    start = text.find("function MNt({enabled:e")
    if start < 0:
        raise ValueError("MNt not found")
    end = text.find("I_e(`thread.runStart`,u)}", start)
    if end < 0:
        raise ValueError("MNt end marker not found")
    end += len("I_e(`thread.runStart`,u)}")
    return text[:start] + NEW_MNT + text[end:]


def main() -> int:
    if not ASAR.is_file():
        print(f"missing {ASAR}", file=sys.stderr)
        return 1
    if EXTRACT.exists():
        import shutil

        shutil.rmtree(EXTRACT)
    EXTRACT.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        _npx_cmd() + ["extract", str(ASAR), str(EXTRACT)],
        check=True,
        shell=os.name == "nt",
    )
    js = next((EXTRACT / "dist" / "assets").glob("index-*.js"))
    text = _apply(js.read_text(encoding="utf-8"))
    js.write_text(text, encoding="utf-8")
    subprocess.run(
        _npx_cmd() + ["pack", str(EXTRACT), str(ASAR)],
        check=True,
        shell=os.name == "nt",
    )
    print(f"patched {ASAR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
