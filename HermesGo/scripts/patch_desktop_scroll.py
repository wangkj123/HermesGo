"""Patch Hermes Desktop app.asar scroll pinning (MNt) for portable green builds.

Run from repo after editing the patch logic below; requires Node npx @electron/asar.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]
ASAR = APP_ROOT / "runtime" / "hermes-desktop" / "resources" / "app.asar"
EXTRACT = APP_ROOT / "logs" / "tmp" / "desktop-asar-patch"

OLD_MNT = (
    "function MNt({enabled:e,groupCount:t,scrollerRef:n,sessionKey:r,virtualizer:i})"
    "{let a=(0,P.useRef)(!0),o=(0,P.useRef)(0),s=(0,P.useRef)(r),c=(0,P.useRef)(0),d=(0,P.useRef)(0),"
    "l=(0,P.useCallback)(()=>{let e=n.current;if(!e||!a.current)return;"
    "let t=e.scrollHeight-e.scrollTop-e.clientHeight;if(t>kNt)return;"
    "e.scrollTop=e.scrollHeight,o.current=e.scrollTop},[n]),"
    "u=(0,P.useCallback)(()=>{a.current=!0,d.current=0,requestAnimationFrame(()=>{a.current&&l()})},[t,l,i]);"
    "(0,P.useEffect)(()=>()=>ENt(!1),[]),"
    "(0,P.useEffect)(()=>{let e=n.current;if(!e)return;let r=()=>{a.current=!1,d.current=0},"
    "i=()=>{let r=e.scrollTop,i=e.scrollHeight-(r+e.clientHeight)<=kNt;"
    "r<o.current-2&&(a.current=!1,d.current=0),o.current=r,"
    "i?(d.current=d.current+1,d.current>=2&&(a.current=!0)):(d.current=0,a.current=!1),ENt(!i)},"
    "s=e=>{e.deltaY<0&&r()};"
    "return e.addEventListener(`scroll`,i,{passive:!0}),e.addEventListener(`wheel`,s,{passive:!0}),"
    "e.addEventListener(`touchmove`,r,{passive:!0}),"
    "()=>{e.removeEventListener(`scroll`,i),e.removeEventListener(`wheel`,s),e.removeEventListener(`touchmove`,r)}"
    "},[n]),"
    "(0,P.useEffect)(()=>{if(!e)return;let t=n.current;if(!t)return;let r=new ResizeObserver(()=>{a.current&&l()});"
    "return r.observe(t),t.firstElementChild&&r.observe(t.firstElementChild),()=>r.disconnect()},[e,l,n]),"
    "(0,P.useEffect)(()=>{let n=s.current!==r,i=c.current===0&&t>0;s.current=r,c.current=t,e&&(n||i)&&u()},[e,t,u,r]),"
    "I_e(`thread.runStart`,u)}"
)

NEW_MNT = (
    "function MNt({enabled:e,groupCount:t,scrollerRef:n,sessionKey:r,virtualizer:i})"
    "{let a=(0,P.useRef)(!0),o=(0,P.useRef)(0),s=(0,P.useRef)(r),c=(0,P.useRef)(0),d=(0,P.useRef)(0),"
    "f=(0,P.useRef)(!1),p=(0,P.useRef)(null),"
    "h=()=>{let e=n.current,t=document.getSelection();if(!e||!t||t.isCollapsed)return!1;"
    "let r=t.anchorNode;return!!r&&e.contains(r)},"
    "m=()=>{f.current=!0,a.current=!1,d.current=0},"
    "g=(0,P.useCallback)(()=>{let e=n.current;if(!e||!a.current||f.current||h())return;"
    "let t=e.scrollHeight-e.scrollTop-e.clientHeight;if(t>kNt)return;"
    "e.scrollTop=e.scrollHeight,o.current=e.scrollTop},[n]),"
    "u=(0,P.useCallback)(()=>{f.current=!1,a.current=!0,d.current=0,"
    "requestAnimationFrame(()=>{a.current&&!f.current&&!h()&&g()})},[g]);"
    "(0,P.useEffect)(()=>()=>ENt(!1),[]),"
    "(0,P.useEffect)(()=>{let e=n.current;if(!e)return;e.style.overflowAnchor=`none`;"
    "let t=()=>{m()},r=()=>{h()?m():f.current=!1},i=()=>{"
    "if(f.current||h()){ENt(!0);return};"
    "let r=e.scrollTop,i=e.scrollHeight-(r+e.clientHeight)<=kNt;"
    "r<o.current-2&&(a.current=!1,d.current=0),o.current=r,"
    "i?(d.current=d.current+1,d.current>=2&&(a.current=!0)):(d.current=0,a.current=!1),ENt(!i)},"
    "s=e=>{e.deltaY<0&&t()};"
    "return document.addEventListener(`selectionchange`,r),"
    "e.addEventListener(`pointerdown`,t,{passive:!0}),e.addEventListener(`mousedown`,t,{passive:!0}),"
    "e.addEventListener(`scroll`,i,{passive:!0}),e.addEventListener(`wheel`,s,{passive:!0}),"
    "e.addEventListener(`touchstart`,t,{passive:!0}),"
    "()=>{document.removeEventListener(`selectionchange`,r),"
    "e.removeEventListener(`pointerdown`,t),e.removeEventListener(`mousedown`,t),"
    "e.removeEventListener(`scroll`,i),e.removeEventListener(`wheel`,s),"
    "e.removeEventListener(`touchstart`,t)}},[n]),"
    "(0,P.useEffect)(()=>{if(!e)return;let t=n.current;if(!t)return;let r=null,"
    "i=new ResizeObserver(()=>{if(f.current||h()||!a.current)return;"
    "r!==null&&cancelAnimationFrame(r),r=requestAnimationFrame(()=>{r=null,a.current&&!f.current&&!h()&&g()})});"
    "return i.observe(t),t.firstElementChild&&r.observe(t.firstElementChild),"
    "()=>{r!==null&&cancelAnimationFrame(r),i.disconnect()}},[e,g,n]),"
    "(0,P.useEffect)(()=>{if(!e)return;let i=n.current;if(!i||a.current||f.current)return;"
    "let r=i.scrollTop;p.current=r,requestAnimationFrame(()=>{requestAnimationFrame(()=>{"
    "if(!i||a.current||f.current||h())return;let e=p.current;e!=null&&Math.abs(i.scrollTop-e)>3&&"
    "(i.scrollTop=e,o.current=e)})})},[t,e]),"
    "(0,P.useEffect)(()=>{let n=s.current!==r,i=c.current===0&&t>0;s.current=r,c.current=t,e&&(n||i)&&u()},[e,t,u,r]),"
    "I_e(`thread.runStart`,u)}"
)


def main() -> int:
    if not ASAR.is_file():
        print(f"missing {ASAR}", file=sys.stderr)
        return 1
    if EXTRACT.exists():
        import shutil
        shutil.rmtree(EXTRACT)
    EXTRACT.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["npx", "--yes", "@electron/asar", "extract", str(ASAR), str(EXTRACT)],
        check=True,
    )
    js_files = list((EXTRACT / "dist" / "assets").glob("index-*.js"))
    if not js_files:
        print("no index-*.js in asar", file=sys.stderr)
        return 1
    js = js_files[0]
    text = js.read_text(encoding="utf-8")
    text = text.replace("var DNt=220,ONt=4,kNt=120;", "var DNt=220,ONt=4,kNt=48;")
    text = text.replace("var DNt=220,ONt=4,kNt=280;", "var DNt=220,ONt=4,kNt=48;")
    if OLD_MNT in text:
        text = text.replace(OLD_MNT, NEW_MNT, 1)
    elif NEW_MNT[:80] not in text:
        print("MNt block not found; asar may already be patched or layout changed", file=sys.stderr)
        return 1
    js.write_text(text, encoding="utf-8")
    subprocess.run(
        ["npx", "--yes", "@electron/asar", "pack", str(EXTRACT), str(ASAR)],
        check=True,
    )
    print(f"patched {ASAR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
