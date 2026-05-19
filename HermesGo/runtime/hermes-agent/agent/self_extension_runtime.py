"""Bootstrap Hermes self-extension runs on top of run/checkpoint/verify state."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional
import shutil
import uuid

from agent.run_registry import (
    CheckpointRecord,
    RunRecord,
    StageRecord,
    UnitRecord,
    write_checkpoint,
    write_run_record,
    write_stage_record,
    write_unit_record,
)

SELFEXT_CONTEXT_RELATIVE_PATHS = (
    ".cursorrules",
    "AGENTS.md",
    ".codexrc",
    ".codex-system-prompt",
    "README.md",
    "docs/031-2026-04-19-HermesGo-Codex登录隔离与断开修复归档.md",
    "docs/036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md",
    "docs/037-2026-04-23-HermesGo模块拆分与文档治理执行方案.md",
    "docs/038-2026-04-23-HermesGo多Profile与凭据隔离设计.md",
    "docs/039-2026-04-23-HermesGo连续执行检查点与恢复设计.md",
    "docs/040-2026-04-23-HermesGo自动验证与失败回读设计.md",
    "docs/041-2026-04-23-HermesGo账号租约池与多角色监控设计.md",
    "docs/043-2026-04-23-HermesGo阶段划分与Hermes自展替代路径评估.md",
    "docs/044-2026-04-23-HermesGo完全自展路线与内生账号池基线.md",
    "docs/045-2026-04-24-HermesGo自展底部第一轮实现归档.md",
    "docs/046-2026-04-24-HermesGo多LLM现成网关优先与难度路由基线.md",
    "docs/047-2026-04-24-HermesGo现成网关与三档任务路由第一轮实现归档.md",
    "docs/048-2026-04-24-HermesGo统一前台Key与自展任务启动第一轮实现归档.md",
    "docs/050-2026-04-24-HermesGo网关池命令与自展入口第一轮实现归档.md",
    "docs/00-governance/conflict-index.md",
)


def _workspace_context_target(rel: str) -> str:
    normalized = rel.replace("\\", "/")
    if normalized == "README.md":
        return "selfext/README.md"
    if normalized.startswith("docs/"):
        return f"selfext/{normalized}"
    return normalized


def _resolve_context_source_path(source_root: Path, rel: str) -> Path:
    primary = source_root / rel
    if primary.exists():
        return primary

    normalized = rel.replace("\\", "/")
    if normalized == "README.md":
        alternate = source_root / "selfext" / "README.md"
        if alternate.exists():
            return alternate
    elif normalized.startswith("docs/"):
        alternate = source_root / "selfext" / normalized
        if alternate.exists():
            return alternate

    return primary


def _make_run_id(prefix: str = "selfext") -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    return f"{prefix}-{stamp}-{uuid.uuid4().hex[:6]}"


@dataclass
class SelfExtensionBootstrapResult:
    run_id: str
    stage_ids: List[str]
    first_unit_id: str
    route_tier: str
    gateway_model_name: str


@dataclass
class SelfExtensionWorkspaceResult:
    run_id: str
    workspace_root: str
    hermesgo_dir: str
    handoff_file: str
    manifest_file: str
    start_guide_file: str
    launcher_file: str
    copied_paths: List[str]
    route_tier: str
    gateway_model_name: str


def bootstrap_self_extension_run(
    *,
    goal: str,
    profile_name: str = "default",
    route_tier: str = "strong",
    gateway_model_name: str = "strong",
    run_id: Optional[str] = None,
    extra_metadata: Optional[Dict[str, str]] = None,
    artifact_paths: Optional[List[str]] = None,
    initial_output_summary: str = "self-extension run bootstrapped",
) -> SelfExtensionBootstrapResult:
    effective_run_id = run_id or _make_run_id()
    common_meta: Dict[str, str] = {
        "kind": "self_extension",
        "run_type": "selfext_objective",
        "selfext_scope": "hermes_self_improvement",
        "route_tier": route_tier,
        "gateway_model_name": gateway_model_name,
    }
    if extra_metadata:
        common_meta.update(extra_metadata)

    run = RunRecord(
        run_id=effective_run_id,
        goal=goal,
        profile_name=profile_name,
        status="running",
        current_stage_id="analyze",
        current_unit_id="u1",
        metadata=dict(common_meta),
    )
    write_run_record(run)

    stages = [
        StageRecord(
            run_id=effective_run_id,
            stage_id="analyze",
            name="analyze",
            status="running",
            metadata={"owner": "architect", **common_meta},
        ),
        StageRecord(
            run_id=effective_run_id,
            stage_id="implement",
            name="implement",
            status="pending",
            metadata={"owner": "builder", **common_meta},
        ),
        StageRecord(
            run_id=effective_run_id,
            stage_id="verify",
            name="verify",
            status="pending",
            metadata={"owner": "tester", **common_meta},
        ),
        StageRecord(
            run_id=effective_run_id,
            stage_id="archive",
            name="archive",
            status="pending",
            metadata={"owner": "archiver", **common_meta},
        ),
    ]
    for stage in stages:
        write_stage_record(stage)

    first_unit = UnitRecord(
        run_id=effective_run_id,
        stage_id="analyze",
        unit_id="u1",
        name="plan-self-extension",
        status="checkpointed",
        next_action="continue",
        metadata={"owner": "architect", **common_meta},
    )
    write_unit_record(first_unit)

    checkpoint = CheckpointRecord(
        run_id=effective_run_id,
        stage_id="analyze",
        unit_id="u1",
        profile_name=profile_name,
        status="checkpointed",
        input_summary=goal,
        output_summary=initial_output_summary,
        artifact_paths=list(artifact_paths or []),
        next_action="continue",
        metadata={"stage": "analyze", **common_meta},
    )
    write_checkpoint(checkpoint)

    return SelfExtensionBootstrapResult(
        run_id=effective_run_id,
        stage_ids=[stage.stage_id for stage in stages],
        first_unit_id="u1",
        route_tier=route_tier,
        gateway_model_name=gateway_model_name,
    )


def bootstrap_self_extension_run_dict(**kwargs) -> Dict[str, object]:
    return asdict(bootstrap_self_extension_run(**kwargs))


def _copy_path(src: Path, dst: Path) -> None:
    if src.is_dir():
        shutil.copytree(src, dst, dirs_exist_ok=True)
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _iter_existing_rule_files(source_root: Path) -> List[Path]:
    rules_dir = source_root / ".cursor" / "rules"
    if not rules_dir.is_dir():
        return []
    return sorted(path for path in rules_dir.glob("*.mdc") if path.is_file())


def prepare_self_extension_workspace(
    *,
    goal: str,
    source_root: Path | str,
    workspace_root: Path | str,
    profile_name: str = "default",
    route_tier: str = "strong",
    gateway_model_name: str = "strong",
    run_id: Optional[str] = None,
    hermesgo_dir_name: str = "HermesGo",
) -> SelfExtensionWorkspaceResult:
    source_root_path = Path(source_root).resolve()
    workspace_root_path = Path(workspace_root).resolve()
    hermesgo_source = source_root_path / "HermesGo"
    hermesgo_target = workspace_root_path / hermesgo_dir_name

    if not hermesgo_source.is_dir():
        raise FileNotFoundError(f"HermesGo directory not found under source root: {hermesgo_source}")

    workspace_root_path.mkdir(parents=True, exist_ok=True)

    copied_paths: List[str] = []
    for rel in SELFEXT_CONTEXT_RELATIVE_PATHS:
        src = _resolve_context_source_path(source_root_path, rel)
        if not src.exists():
            continue
        target_rel = _workspace_context_target(rel)
        _copy_path(src, workspace_root_path / target_rel)
        copied_paths.append(target_rel)

    for rule_file in _iter_existing_rule_files(source_root_path):
        rel = rule_file.relative_to(source_root_path)
        _copy_path(rule_file, workspace_root_path / rel)
        copied_paths.append(str(rel).replace("\\", "/"))

    _copy_path(hermesgo_source, hermesgo_target)
    copied_paths.append(f"{hermesgo_dir_name}/")

    handoff_relative = "selfext/SELFEXT-WORKSPACE.md"
    handoff_path = workspace_root_path / handoff_relative
    handoff_content = "\n".join(
        [
            "# HermesGo 自展接管工作区",
            "",
            f"- 目标：{goal}",
            f"- 源仓库：{source_root_path}",
            f"- 当前接管目录：{workspace_root_path}",
            f"- 实际工作目录：{hermesgo_target}",
            f"- 推荐命令：cd {hermesgo_target}",
            "",
            "## 接管要求",
            "",
            "1. 先读取工作区根目录 `.cursorrules` 与 `AGENTS.md`。",
            "2. 如存在 `.cursor/rules/*.mdc`，继续读取并遵守。",
            "3. 当前路线以 HermesGo `selfext` 为先，账号由用户手工登录，不做共享登录态轮换。",
            "4. 目标文档以复制进来的 `selfext/docs/031`、`selfext/docs/036`、`selfext/docs/037` 到 `selfext/docs/041`、`selfext/docs/043` 到 `selfext/docs/048`、`selfext/docs/050` 和 `selfext/docs/00-governance/conflict-index.md` 为准。",
            "",
            "## 本工作区用途",
            "",
            "- 作为 HermesGo 自展独立工作区。",
            "- 规则和目标文档已经复制到此目录。",
            "- `HermesGo/` 子目录保留实际源码与运行入口，后续工作应转到该目录继续。",
            "- 启动步骤已写入 `selfext/START-SELFEXT.md`。",
            "",
        ]
    )
    _write_text(handoff_path, handoff_content)
    copied_paths.append(handoff_relative)

    launcher_relative = "SELFEXT.bat"
    launcher_path = workspace_root_path / launcher_relative
    bootstrap_dir = workspace_root_path / "selfext" / "bootstrap"
    current_dir = workspace_root_path / "selfext" / "current"
    logs_dir = workspace_root_path / "selfext" / "logs"
    bootstrap_dir.mkdir(parents=True, exist_ok=True)
    current_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    ensure_script_name = "Ensure-SelfExtWorkspace.ps1"
    run_script_name = "Run-SelfExt.ps1"
    bootstrap_ensure_path = bootstrap_dir / ensure_script_name
    bootstrap_run_path = bootstrap_dir / run_script_name
    current_ensure_path = current_dir / ensure_script_name
    current_run_path = current_dir / run_script_name

    launcher_content = "\r\n".join(
        [
            "@echo off",
            "setlocal EnableExtensions",
            'set "ROOT=%~dp0"',
            'if "%ROOT:~-1%"=="\\" set "ROOT=%ROOT:~0,-1%"',
            'set \"BOOTSTRAP=%ROOT%\\selfext\\bootstrap\"',
            'set \"CURRENT=%ROOT%\\selfext\\current\"',
            'if not exist \"%CURRENT%\" mkdir \"%CURRENT%\" >\"%SystemRoot%\\System32\\NUL\" 2>\"%SystemRoot%\\System32\\NUL\"',
            'call :ensure_script \"Ensure-SelfExtWorkspace.ps1\"',
            'call :ensure_script \"Run-SelfExt.ps1\"',
            'powershell -NoProfile -ExecutionPolicy Bypass -File \"%CURRENT%\\Ensure-SelfExtWorkspace.ps1\" -WorkspaceRoot \"%ROOT%\"',
            'if errorlevel 1 (',
            '  echo [SELFEXT] workspace check failed, restoring mutable scripts and retrying once.',
            '  call :restore_scripts',
            '  powershell -NoProfile -ExecutionPolicy Bypass -File \"%CURRENT%\\Ensure-SelfExtWorkspace.ps1\" -WorkspaceRoot \"%ROOT%\"',
            '  if errorlevel 1 exit /b %errorlevel%',
            ')',
            'powershell -NoProfile -ExecutionPolicy Bypass -File \"%CURRENT%\\Run-SelfExt.ps1\" -WorkspaceRoot \"%ROOT%\" %*',
            'if errorlevel 1 (',
            '  echo [SELFEXT] runtime script failed, restoring mutable scripts and retrying once.',
            '  call :restore_scripts',
            '  powershell -NoProfile -ExecutionPolicy Bypass -File \"%CURRENT%\\Run-SelfExt.ps1\" -WorkspaceRoot \"%ROOT%\" %*',
            ')',
            'exit /b %errorlevel%',
            '',
            ':ensure_script',
            'if not exist \"%CURRENT%\\%~1\" copy /y \"%BOOTSTRAP%\\%~1\" \"%CURRENT%\\%~1\" >\"%SystemRoot%\\System32\\NUL\"',
            'exit /b 0',
            '',
            ':restore_scripts',
            'copy /y \"%BOOTSTRAP%\\*.ps1\" \"%CURRENT%\\\" >\"%SystemRoot%\\System32\\NUL\"',
            'exit /b 0',
            '',
        ]
    )
    _write_text(launcher_path, launcher_content)
    copied_paths.append(launcher_relative)

    ensure_script_content = "\n".join(
        [
            "param(",
            "    [string]$WorkspaceRoot",
            ")",
            "",
            "Set-StrictMode -Version Latest",
            '$ErrorActionPreference = "Stop"',
            "",
            "$resolvedRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)",
            "$requiredRelativePaths = @(",
            '    ".cursorrules",',
            '    "AGENTS.md",',
            '    "selfext\\README.md",',
            '    "SELFEXT.bat",',
            '    "selfext\\SELFEXT-WORKSPACE.md",',
            '    "selfext\\START-SELFEXT.md",',
            '    "selfext\\workspace-manifest.json",',
            '    "HermesGo",',
            '    "HermesGo\\HermesGo.bat",',
            '    "HermesGo\\Verify-HermesGo.bat",',
            '    "HermesGo\\codex.cmd",',
            '    "selfext\\docs",',
            '    "selfext\\docs\\00-governance"',
            ")",
            "",
            "$missing = New-Object System.Collections.Generic.List[string]",
            "foreach ($relativePath in $requiredRelativePaths) {",
            "    $absolutePath = Join-Path $resolvedRoot $relativePath",
            "    if (-not (Test-Path -LiteralPath $absolutePath)) {",
            "        [void]$missing.Add($relativePath)",
            "    }",
            "}",
            "",
            'New-Item -ItemType Directory -Path (Join-Path $resolvedRoot "selfext\\logs") -Force | Out-Null',
            'New-Item -ItemType Directory -Path (Join-Path $resolvedRoot "selfext\\current") -Force | Out-Null',
            'New-Item -ItemType Directory -Path (Join-Path $resolvedRoot "selfext\\bootstrap") -Force | Out-Null',
            "",
            "if ($missing.Count -gt 0) {",
            '    throw ("Self-extension workspace is missing required paths: " + ($missing -join ", "))',
            "}",
            "",
            'Write-Host "[SELFEXT] workspace check passed: $resolvedRoot"',
            "",
        ]
    )
    _write_text(bootstrap_ensure_path, ensure_script_content)
    if not current_ensure_path.exists():
        _write_text(current_ensure_path, ensure_script_content)
    copied_paths.append("selfext/bootstrap/Ensure-SelfExtWorkspace.ps1")
    if "selfext/current/Ensure-SelfExtWorkspace.ps1" not in copied_paths:
        copied_paths.append("selfext/current/Ensure-SelfExtWorkspace.ps1")

    start_guide_relative = "selfext/START-SELFEXT.md"
    start_guide_path = workspace_root_path / start_guide_relative
    start_guide_content = "\n".join(
        [
            "# HermesGo 自展启动指南",
            "",
            "## 1. 最稳的入口：先用 BAT",
            "",
            f"```powershell\ncd {workspace_root_path}\n.\\SELFEXT.bat help\n```",
            "",
            "默认建议顺序：",
            "",
            f"```powershell\ncd {workspace_root_path}\n.\\SELFEXT.bat doctor\n.\\SELFEXT.bat login\n.\\SELFEXT.bat launch\n.\\SELFEXT.bat status\n```",
            "",
            "## 2. BAT 做了什么",
            "",
            "- `SELFEXT.bat` 是稳定入口，后续尽量不要改它。",
            "- `selfext/current/*.ps1` 是可改的运行脚本。",
            "- `selfext/bootstrap/*.ps1` 是保底副本。",
            "- 如果 `current` 里的脚本报错，BAT 会自动用 `bootstrap` 副本恢复并重试一次。",
            "",
            "## 3. 先手工完成账号登录",
            "",
            "推荐两种方式，任选其一：",
            "",
            f"```powershell\ncd {workspace_root_path}\n.\\SELFEXT.bat login\n```",
            "",
            "或者直接双击：",
            "",
            f"- `{hermesgo_target}\\HermesGo.exe`",
            "",
            "说明：当前路线保留手工登录，不做共享登录态轮换。",
            "",
            "## 4. 登录后开始自展",
            "",
            "先看 `selfext/` 下面这些文件：",
            "",
            "- `.cursorrules`",
            "- `AGENTS.md`",
            "- `selfext/docs/036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md`",
            "- `selfext/docs/043-2026-04-23-HermesGo阶段划分与Hermes自展替代路径评估.md`",
            "- `selfext/docs/044-2026-04-23-HermesGo完全自展路线与内生账号池基线.md`",
            "- `selfext/docs/045-2026-04-24-HermesGo自展底部第一轮实现归档.md`",
            "- `selfext/docs/046-2026-04-24-HermesGo多LLM现成网关优先与难度路由基线.md`",
            "- `selfext/docs/048-2026-04-24-HermesGo统一前台Key与自展任务启动第一轮实现归档.md`",
            "- `selfext/docs/050-2026-04-24-HermesGo网关池命令与自展入口第一轮实现归档.md`",
            "",
            "## 5. 查看当前自展 run",
            "",
            f"```powershell\ncd {workspace_root_path}\n.\\SELFEXT.bat status\n```",
            "",
            "## 6. 当前最小开工顺序",
            "",
            "1. 先 `SELFEXT.bat doctor`。",
            "2. 再 `SELFEXT.bat login`。",
            "3. 再 `SELFEXT.bat launch`。",
            "4. 再 `SELFEXT.bat status`。",
            "5. 然后读规则和文档，再回到 `HermesGo/` 目录做代码与验证。",
            "6. 优先沿 `selfext -> gateway-pool -> verification -> resume/retry` 继续收口。",
            "",
        ]
    )
    start_guide_path.write_text(start_guide_content, encoding="utf-8")
    copied_paths.append(start_guide_relative)

    run_script_content = "\n".join(
        [
            "param(",
            "    [string]$WorkspaceRoot",
            ")",
            "",
            "Set-StrictMode -Version Latest",
            '$ErrorActionPreference = "Stop"',
            "",
            "$resolvedRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)",
            '$manifestPath = Join-Path $resolvedRoot "selfext\\workspace-manifest.json"',
            '$startGuidePath = Join-Path $resolvedRoot "selfext\\START-SELFEXT.md"',
            '$hermesgoDir = Join-Path $resolvedRoot "HermesGo"',
            '$verifyBat = Join-Path $hermesgoDir "Verify-HermesGo.bat"',
            '$launchBat = Join-Path $hermesgoDir "HermesGo.bat"',
            '$codexCmd = Join-Path $hermesgoDir "codex.cmd"',
            '$pythonExe = Join-Path $hermesgoDir "runtime\\python311\\python.exe"',
            "",
            "function Get-Manifest {",
            "    if (-not (Test-Path -LiteralPath $manifestPath)) {",
            '        throw "Manifest not found: $manifestPath"',
            "    }",
            "    return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json",
            "}",
            "",
            "$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }",
            "$extraArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }",
            "",
            "switch ($command) {",
            "    'help' {",
            '        Write-Host "SELFEXT commands:"',
            '        Write-Host "  SELFEXT.bat doctor  - verify workspace and HermesGo package"',
            '        Write-Host "  SELFEXT.bat login   - run manual Codex login inside HermesGo"',
            '        Write-Host "  SELFEXT.bat launch  - start HermesGo launcher/runtime"',
            '        Write-Host "  SELFEXT.bat status  - show current selfext run"',
            '        Write-Host "  SELFEXT.bat readme  - print selfext\\START-SELFEXT.md"',
            "        return",
            "    }",
            "    'doctor' {",
            "        Push-Location $hermesgoDir",
            "        try {",
            "            & $verifyBat @extraArgs",
            "            if ($LASTEXITCODE -ne 0) {",
            "                exit $LASTEXITCODE",
            "            }",
            "        } finally {",
            "            Pop-Location",
            "        }",
            '        Write-Host "[SELFEXT] doctor passed."',
            "        return",
            "    }",
            "    'login' {",
            "        Push-Location $hermesgoDir",
            "        try {",
            "            & $codexCmd login @extraArgs",
            "            exit $LASTEXITCODE",
            "        } finally {",
            "            Pop-Location",
            "        }",
            "    }",
            "    'launch' {",
            "        Push-Location $hermesgoDir",
            "        try {",
            "            & $launchBat @extraArgs",
            "            exit $LASTEXITCODE",
            "        } finally {",
            "            Pop-Location",
            "        }",
            "    }",
            "    'status' {",
            "        $manifest = Get-Manifest",
            '        Write-Host "[SELFEXT] current workspace manifest:"',
            "        $manifest | ConvertTo-Json -Depth 6",
            "        return",
            "    }",
            "    'readme' {",
            "        Get-Content -LiteralPath $startGuidePath -Encoding utf8",
            "        return",
            "    }",
            "    default {",
            '        throw ("Unsupported SELFEXT command: " + $command)',
            "    }",
            "}",
            "",
        ]
    )
    _write_text(bootstrap_run_path, run_script_content)
    if not current_run_path.exists():
        _write_text(current_run_path, run_script_content)
    copied_paths.append("selfext/bootstrap/Run-SelfExt.ps1")
    if "selfext/current/Run-SelfExt.ps1" not in copied_paths:
        copied_paths.append("selfext/current/Run-SelfExt.ps1")

    manifest_relative = "selfext/workspace-manifest.json"
    manifest_path = workspace_root_path / manifest_relative
    bootstrap = bootstrap_self_extension_run(
        goal=goal,
        profile_name=profile_name,
        route_tier=route_tier,
        gateway_model_name=gateway_model_name,
        run_id=run_id,
        extra_metadata={
            "workspace_root": str(workspace_root_path),
            "workspace_hermesgo_dir": str(hermesgo_target),
            "workspace_handoff_file": str(handoff_path),
            "workspace_start_guide_file": str(start_guide_path),
            "workspace_launcher_file": str(launcher_path),
        },
        artifact_paths=[str(handoff_path), str(start_guide_path), str(launcher_path), str(manifest_path)],
        initial_output_summary="self-extension workspace prepared",
    )

    manifest_payload = {
        "run_id": bootstrap.run_id,
        "goal": goal,
        "source_root": str(source_root_path),
        "workspace_root": str(workspace_root_path),
        "hermesgo_dir": str(hermesgo_target),
        "handoff_file": str(handoff_path),
        "start_guide_file": str(start_guide_path),
        "launcher_file": str(launcher_path),
        "copied_paths": copied_paths,
    }
    manifest_path.write_text(__import__("json").dumps(manifest_payload, ensure_ascii=False, indent=2), encoding="utf-8")
    copied_paths.append(manifest_relative)

    return SelfExtensionWorkspaceResult(
        run_id=bootstrap.run_id,
        workspace_root=str(workspace_root_path),
        hermesgo_dir=str(hermesgo_target),
        handoff_file=str(handoff_path),
        manifest_file=str(manifest_path),
        start_guide_file=str(start_guide_path),
        launcher_file=str(launcher_path),
        copied_paths=copied_paths,
        route_tier=bootstrap.route_tier,
        gateway_model_name=bootstrap.gateway_model_name,
    )
