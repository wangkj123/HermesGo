"""CLI helpers for Hermes self-extension runs."""

from __future__ import annotations

import json
from argparse import Namespace
from dataclasses import asdict
from pathlib import Path

from agent.run_registry import find_latest_checkpoint, load_run_record
from agent.self_extension_runtime import bootstrap_self_extension_run, prepare_self_extension_workspace
from hermes_cli.profiles import get_active_profile_name


def _cmd_start(args: Namespace) -> None:
    goal = " ".join(args.goal).strip()
    profile_name = args.profile_name or get_active_profile_name()
    gateway_model_name = args.gateway_model_name or args.route_tier

    result = bootstrap_self_extension_run(
        goal=goal,
        profile_name=profile_name,
        route_tier=args.route_tier,
        gateway_model_name=gateway_model_name,
        run_id=args.run_id,
    )
    print(json.dumps(asdict(result), ensure_ascii=False, indent=2))


def _cmd_show(args: Namespace) -> None:
    run = load_run_record(args.run_id)
    if run is None:
        raise SystemExit(f"Run not found: {args.run_id}")

    checkpoint = find_latest_checkpoint(args.run_id)
    payload = {
        "run": asdict(run),
        "latest_checkpoint": asdict(checkpoint) if checkpoint is not None else None,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def _cmd_prepare_workspace(args: Namespace) -> None:
    goal = " ".join(args.goal).strip()
    profile_name = args.profile_name or get_active_profile_name()
    gateway_model_name = args.gateway_model_name or args.route_tier
    source_root = Path(args.source_root).resolve() if args.source_root else Path.cwd().resolve()
    workspace_dir = Path(args.workspace_dir).resolve() if args.workspace_dir else (Path.cwd().resolve() / "workspaces" / "hermesgo")

    result = prepare_self_extension_workspace(
        goal=goal,
        source_root=source_root,
        workspace_root=workspace_dir,
        profile_name=profile_name,
        route_tier=args.route_tier,
        gateway_model_name=gateway_model_name,
        run_id=args.run_id,
    )
    print(json.dumps(asdict(result), ensure_ascii=False, indent=2))


def selfext_command(args: Namespace) -> None:
    action = getattr(args, "selfext_action", None) or "start"
    if action == "start":
        _cmd_start(args)
        return
    if action == "prepare-workspace":
        _cmd_prepare_workspace(args)
        return
    if action == "show":
        _cmd_show(args)
        return
    raise SystemExit(f"Unsupported selfext action: {action}")
