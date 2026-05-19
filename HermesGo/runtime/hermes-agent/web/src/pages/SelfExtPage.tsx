import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  Bot,
  ClipboardList,
  FileText,
  LoaderCircle,
  Pause,
  Play,
  RefreshCw,
  Rocket,
  Send,
  Shield,
  Sparkles,
  Square,
  Terminal,
  Users,
} from "lucide-react";
import { api } from "@/lib/api";
import type {
  SelfExtActionResponse,
  SelfExtChatResponse,
  SelfExtRunsResponse,
  SelfExtWorkspaceResponse,
} from "@/lib/api";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Markdown } from "@/components/Markdown";

interface ChatTurn {
  role: "user" | "assistant" | "system";
  content: string;
}

const SELFEXT_OBJECTIVE_EXAMPLE =
  "把 SelfExt 控制台迭代成 Hermes 自己可用的持续自展系统：发布自展目标、拆分多子代理、查看每个子代理状态、暂停/恢复/介入、自动验证、失败回读和归档。";

const VALIDATION_SCENARIO_EXAMPLE =
  "验收场景：以自有 Windows 软件的合法注册码/激活系统为样例，验证 Hermes 能先澄清、拆任务、实现、测试和归档；该场景只用于验证自展能力，不是 SelfExt 要交付的业务本体。";

const OTHER_EXAMPLES = [
  "让 Hermes 自动检查 dashboard、运行时、测试和日志，发现缺口后继续迭代到可运行状态。",
  "让 Hermes 建立子代理任务编排：architect / implementer / tester / reviewer 分工、状态回读和人工接管。",
];

function buildGuidedPrompt(
  selfExtObjective: string,
  validationScenario: string,
  clarificationFirst: boolean,
  validationBoundary: boolean,
) {
  const lines = [
    `这是一个 Hermes 自展目标，不是普通用户任务：${selfExtObjective.trim()}`,
    "",
    "SelfExt 的定义：让 HermesGo/Hermes 持续改进自身能力、控制台、运行时、任务编排、验证闭环和交付形态，直到达到我们约定的目标。",
    "不要把用户的外部业务需求当成 SelfExt 本体；外部业务需求只能作为验收场景、测试样例或能力校准输入。",
    "",
  ];
  if (validationScenario.trim()) {
    lines.push(`验收场景：${validationScenario.trim()}`, "");
  }
  if (validationBoundary) {
    lines.push(
      "验收场景边界：如果提到注册码、激活系统或其他业务功能，只能面向我自己的软件、我自己的系统或我明确授权的项目；它们只用于验证 Hermes 自展出的能力，不是 SelfExt 要交付的业务本体。",
      "禁止把 SelfExt 转成破解、绕过、伪造第三方授权或第三方 keygen 任务。",
      "",
    );
  }
  if (clarificationFirst) {
    lines.push(
      "先不要直接写代码，也不要直接执行。",
      "先向我提出你必须确认的关键问题，直到需求足够清楚。",
      "确认完以后：",
      "1. 先给最小可行方案。",
      "2. 把 Hermes 自展目标拆给 architect / implementer / tester / reviewer 四个角色，并说明每个角色的输入、输出、验收标准。",
      "3. 我确认后再开始实现。",
      "4. 每做一步就自检。",
      "5. 失败自动回读日志、修复并重试，直到成功或出现明确阻塞。",
      "6. 如果 dashboard run 状态变为 paused 或 cancelled，必须停在安全检查点并等待人工介入。",
      "7. 最后给我可运行结果、验证结果和使用方法。",
    );
  } else {
    lines.push(
      "直接进入实现，但每做一步都要自检。",
      "把 Hermes 自展目标拆给 architect / implementer / tester / reviewer 四个角色，并说明每个角色的状态。",
      "失败自动回读日志、修复并重试，直到成功或出现明确阻塞。",
      "如果 dashboard run 状态变为 paused 或 cancelled，必须停在安全检查点并等待人工介入。",
      "最后给我可运行结果、验证结果和使用方法。",
    );
  }
  return lines.join("\n").trim();
}

export default function SelfExtPage() {
  const [workspace, setWorkspace] = useState<SelfExtWorkspaceResponse | null>(null);
  const [loadingWorkspace, setLoadingWorkspace] = useState(true);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const [lastAction, setLastAction] = useState<SelfExtActionResponse | null>(null);
  const [selfExtObjective, setSelfExtObjective] = useState("");
  const [validationScenario, setValidationScenario] = useState("");
  const [clarificationFirst, setClarificationFirst] = useState(true);
  const [validationBoundary, setValidationBoundary] = useState(true);
  const [routeTier, setRouteTier] = useState("local");
  const [taskRunId, setTaskRunId] = useState("");
  const [sessionId, setSessionId] = useState("");
  const [chatBusy, setChatBusy] = useState(false);
  const [chatInput, setChatInput] = useState("");
  const [chatTurns, setChatTurns] = useState<ChatTurn[]>([]);
  const [chatError, setChatError] = useState("");
  const [runBoard, setRunBoard] = useState<SelfExtRunsResponse | null>(null);
  const [loadingRuns, setLoadingRuns] = useState(false);
  const [selectedRunId, setSelectedRunId] = useState("");
  const [interventionText, setInterventionText] = useState("");
  const [controlBusy, setControlBusy] = useState<string | null>(null);

  const taskPrompt = useMemo(
    () => buildGuidedPrompt(selfExtObjective, validationScenario, clarificationFirst, validationBoundary),
    [selfExtObjective, validationScenario, clarificationFirst, validationBoundary],
  );

  async function loadWorkspace() {
    setLoadingWorkspace(true);
    try {
      const payload = await api.getSelfExtWorkspace();
      setWorkspace(payload);
    } finally {
      setLoadingWorkspace(false);
    }
  }

  async function loadRunBoard() {
    setLoadingRuns(true);
    try {
      const payload = await api.getSelfExtRuns();
      setRunBoard(payload);
      if (!selectedRunId && payload.runs.length > 0) {
        setSelectedRunId(payload.runs[0].run.run_id);
      }
    } finally {
      setLoadingRuns(false);
    }
  }

  useEffect(() => {
    loadWorkspace().catch(() => {});
    loadRunBoard().catch(() => {});
  }, []);

  async function runAction(action: "doctor" | "launch" | "status" | "readme") {
    setActionBusy(action);
    try {
      const payload = await api.runSelfExtAction(action, action === "doctor" ? 300 : 180);
      setLastAction(payload);
      if (action === "status") {
        await loadWorkspace();
      }
    } catch (error) {
      setLastAction({
        ok: false,
        action,
        command: [],
        exit_code: 1,
        stdout: "",
        stderr: error instanceof Error ? error.message : String(error),
        duration_sec: 0,
      });
    } finally {
      setActionBusy(null);
    }
  }

  async function startTaskSession() {
    if (!selfExtObjective.trim()) {
      return;
    }

    setChatBusy(true);
    setChatError("");
    try {
      const run = await api.startSelfExtRun({
        goal: selfExtObjective.trim(),
        validation_scenario: validationScenario.trim() || undefined,
        route_tier: routeTier,
        gateway_model_name: routeTier,
      });
      setTaskRunId(run.run_id);
      setSelectedRunId(run.run_id);

      const kickoff = await api.runSelfExtChat({
        prompt: taskPrompt,
        timeout_sec: 600,
      });
      applyChatResult(kickoff, `自展目标启动：${selfExtObjective.trim()}`);
      if (kickoff.session_id) {
        await api.controlSelfExtRun(run.run_id, {
          action: "intervene",
          note: `自展对话已绑定 session_id: ${kickoff.session_id}`,
        });
      }
      await loadWorkspace();
      await loadRunBoard();
    } catch (error) {
      setChatError(error instanceof Error ? error.message : String(error));
    } finally {
      setChatBusy(false);
    }
  }

  function applyChatResult(result: SelfExtChatResponse, userMessage: string) {
    setChatTurns((prev) => [
      ...prev,
      { role: "user", content: userMessage },
      { role: "assistant", content: result.response || "(无输出)" },
    ]);
    if (result.session_id) {
      setSessionId(result.session_id);
    }
    if (!result.ok && result.stderr) {
      setChatError(result.stderr);
    } else {
      setChatError("");
    }
  }

  async function continueSession() {
    if (!chatInput.trim()) {
      return;
    }
    setChatBusy(true);
    setChatError("");
    const nextMessage = chatInput.trim();
    try {
      const payload = await api.runSelfExtChat({
        prompt: nextMessage,
        session_id: sessionId || undefined,
        timeout_sec: 600,
      });
      applyChatResult(payload, nextMessage);
      setChatInput("");
      if (taskRunId || selectedRunId) {
        await api.controlSelfExtRun(taskRunId || selectedRunId, {
          action: "intervene",
          note: `人工补充自展要求：${nextMessage}`,
        });
        await loadRunBoard();
      }
    } catch (error) {
      setChatError(error instanceof Error ? error.message : String(error));
    } finally {
      setChatBusy(false);
    }
  }

  async function controlRun(runId: string, action: "pause" | "resume" | "cancel" | "intervene", note?: string) {
    setControlBusy(`${runId}:${action}`);
    try {
      await api.controlSelfExtRun(runId, { action, note });
      if (action === "intervene") {
        setInterventionText("");
      }
      await loadRunBoard();
    } catch (error) {
      setChatError(error instanceof Error ? error.message : String(error));
    } finally {
      setControlBusy(null);
    }
  }

  if (loadingWorkspace && !workspace) {
    return (
      <div className="flex items-center justify-center py-24">
        <LoaderCircle className="h-6 w-6 animate-spin" />
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 xl:grid-cols-[1.05fr_1.35fr]">
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <Terminal className="h-5 w-5 text-primary" />
              <CardTitle>SelfExt 控制台</CardTitle>
            </div>
            <CardDescription>
              用浏览器完成 `doctor / launch / status`，并在当前独立工作区里启动 Hermes 自展目标。
            </CardDescription>
          </CardHeader>

          <CardContent className="flex flex-col gap-4">
            <div className="grid gap-3 sm:grid-cols-2">
              <InfoBlock label="工作区根目录" value={workspace?.workspace_root ?? "-"} />
              <InfoBlock label="HermesGo 包目录" value={workspace?.package_root ?? "-"} />
              <InfoBlock label="当前接管 Run" value={String(workspace?.manifest?.run_id ?? "-")} />
              <InfoBlock label="SelfExt CLI" value={workspace?.selfext_cli_ready ? "ready" : "missing"} />
            </div>

            <div className="flex flex-wrap gap-2">
              <Button variant="outline" onClick={() => loadWorkspace()} disabled={loadingWorkspace}>
                <RefreshCw className={`h-4 w-4 ${loadingWorkspace ? "animate-spin" : ""}`} />
                刷新
              </Button>
              <Button variant="default" onClick={() => runAction("doctor")} disabled={!!actionBusy}>
                {actionBusy === "doctor" ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Shield className="h-4 w-4" />}
                Doctor
              </Button>
              <Button variant="secondary" onClick={() => runAction("launch")} disabled={!!actionBusy}>
                {actionBusy === "launch" ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Rocket className="h-4 w-4" />}
                Launch
              </Button>
              <Button variant="outline" onClick={() => runAction("status")} disabled={!!actionBusy}>
                Status
              </Button>
              <Button variant="ghost" onClick={() => runAction("readme")} disabled={!!actionBusy}>
                <FileText className="h-4 w-4" />
                启动说明
              </Button>
              <a href={workspace?.keys_page_path ?? "/env"} className="inline-flex">
                <Button variant="outline">登录 / Keys</Button>
              </a>
            </div>

            <div className="border border-border bg-secondary/20 p-3 text-xs text-muted-foreground">
              登录已经是浏览器流程，入口在 `Keys` 页面；这里主要负责工作区启动、自检、状态查看和自展目标启动。
            </div>

            <ConsoleBlock
              title={lastAction ? `最近动作：${lastAction.action}` : "最近动作输出"}
              text={
                lastAction
                  ? [lastAction.stdout, lastAction.stderr && `stderr:\n${lastAction.stderr}`].filter(Boolean).join("\n\n")
                  : workspace?.debug_log_tail?.join("\n") ?? ""
              }
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <Sparkles className="h-5 w-5 text-primary" />
              <CardTitle>自展目标启动</CardTitle>
            </div>
            <CardDescription>
              这里只发布 Hermes 自身迭代目标。业务需求只能放在验收场景里，用来验证自展能力。
            </CardDescription>
          </CardHeader>

          <CardContent className="flex flex-col gap-4">
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" size="sm" onClick={() => setSelfExtObjective(SELFEXT_OBJECTIVE_EXAMPLE)}>
                自展控制台闭环
              </Button>
              <Button variant="outline" size="sm" onClick={() => setValidationScenario(VALIDATION_SCENARIO_EXAMPLE)}>
                注册/激活验收场景
              </Button>
              {OTHER_EXAMPLES.map((example) => (
                <Button key={example} variant="ghost" size="sm" onClick={() => setSelfExtObjective(example)}>
                  {example}
                </Button>
              ))}
            </div>

            <label className="flex flex-col gap-2">
              <span className="text-xs uppercase tracking-[0.14em] text-muted-foreground">自展目标</span>
              <textarea
                value={selfExtObjective}
                onChange={(event) => setSelfExtObjective(event.target.value)}
                rows={4}
                className="min-h-28 w-full border border-border bg-secondary/20 px-3 py-2 text-sm outline-none focus:border-foreground/40"
                placeholder="例如：把 Hermes 的 SelfExt 控制台迭代到可发布自展目标、拆分子代理、控制暂停/恢复、自动验证和归档。"
              />
            </label>

            <label className="flex flex-col gap-2">
              <span className="text-xs uppercase tracking-[0.14em] text-muted-foreground">验收场景，不是 SelfExt 本体</span>
              <textarea
                value={validationScenario}
                onChange={(event) => setValidationScenario(event.target.value)}
                rows={3}
                className="min-h-20 w-full border border-border bg-secondary/20 px-3 py-2 text-sm outline-none focus:border-foreground/40"
                placeholder="例如：用自有软件合法注册/激活系统作为验收样例，验证 Hermes 的澄清、拆解、实现、测试和归档能力。"
              />
            </label>

            <div className="grid gap-3 sm:grid-cols-3">
              <label className="flex items-center gap-2 border border-border px-3 py-2 text-sm">
                <input
                  type="checkbox"
                  checked={clarificationFirst}
                  onChange={(event) => setClarificationFirst(event.target.checked)}
                />
                先提问再执行
              </label>
              <label className="flex items-center gap-2 border border-border px-3 py-2 text-sm">
                <input
                  type="checkbox"
                  checked={validationBoundary}
                  onChange={(event) => setValidationBoundary(event.target.checked)}
                />
                验收场景边界
              </label>
              <label className="flex items-center gap-2 border border-border px-3 py-2 text-sm">
                路由
                <select
                  value={routeTier}
                  onChange={(event) => setRouteTier(event.target.value)}
                  className="ml-auto bg-transparent outline-none"
                >
                  <option value="local">local</option>
                  <option value="medium">medium</option>
                  <option value="strong">strong</option>
                </select>
              </label>
            </div>

            <div className="border border-border bg-secondary/20 p-3">
              <div className="mb-2 flex items-center gap-2 text-xs uppercase tracking-[0.14em] text-muted-foreground">
                <FileText className="h-4 w-4" />
                将要发给 HermesGo 的启动提示词
              </div>
              <pre className="whitespace-pre-wrap text-xs leading-relaxed text-foreground/90">{taskPrompt}</pre>
            </div>

            <div className="flex flex-wrap gap-2">
              <Button onClick={() => startTaskSession()} disabled={chatBusy || !selfExtObjective.trim()}>
                {chatBusy ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
                开始自展
              </Button>
              {taskRunId && <Badge variant="outline">run: {taskRunId}</Badge>}
              {sessionId && <Badge variant="success">session: {sessionId}</Badge>}
            </div>

            <div className="border border-border bg-card/60">
              <div className="border-b border-border px-4 py-3 text-xs uppercase tracking-[0.14em] text-muted-foreground">
                任务对话
              </div>
              <div className="flex max-h-[420px] flex-col gap-3 overflow-y-auto p-4">
                {chatTurns.length === 0 && (
                  <div className="text-sm text-muted-foreground">
                    先点“开始自展”。第一次响应建议让它只提问题，不要直接实现。
                  </div>
                )}
                {chatTurns.map((turn, index) => (
                  <div key={`${turn.role}-${index}`} className="border border-border bg-secondary/15 p-3">
                    <div className="mb-2 flex items-center gap-2 text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
                      {turn.role === "assistant" ? <Bot className="h-4 w-4" /> : <Terminal className="h-4 w-4" />}
                      {turn.role}
                    </div>
                    {turn.role === "assistant" ? (
                      <Markdown content={turn.content} />
                    ) : (
                      <div className="whitespace-pre-wrap text-sm leading-relaxed">{turn.content}</div>
                    )}
                  </div>
                ))}
              </div>
              <div className="border-t border-border p-4">
                <textarea
                  value={chatInput}
                  onChange={(event) => setChatInput(event.target.value)}
                  rows={4}
                  className="mb-3 min-h-24 w-full border border-border bg-secondary/20 px-3 py-2 text-sm outline-none focus:border-foreground/40"
                  placeholder="回答上一步问题，或者补充新的自展限制、目标、技术栈。"
                />
                <div className="flex flex-wrap items-center gap-2">
                  <Button onClick={() => continueSession()} disabled={chatBusy || !chatInput.trim()}>
                    {chatBusy ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
                    继续对话
                  </Button>
                  {chatError && <span className="text-xs text-destructive">{chatError}</span>}
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <div className="flex items-center gap-2">
                <ClipboardList className="h-5 w-5 text-primary" />
                <CardTitle>自展任务板</CardTitle>
              </div>
              <CardDescription>
                查看 run、角色阶段、检查点与人工介入记录。暂停/取消会写入状态，后续执行器必须在检查点读取并遵守。
              </CardDescription>
            </div>
            <Button variant="outline" onClick={() => loadRunBoard()} disabled={loadingRuns}>
              <RefreshCw className={`h-4 w-4 ${loadingRuns ? "animate-spin" : ""}`} />
              刷新任务
            </Button>
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <div className="grid gap-3 md:grid-cols-[1fr_320px]">
            <div className="grid gap-3">
              {(!runBoard || runBoard.runs.length === 0) && (
                <div className="border border-border bg-secondary/10 p-4 text-sm text-muted-foreground">
                  暂无 SelfExt run。先在上方发布一个自展目标。
                </div>
              )}
              {runBoard?.runs.map((item) => {
                const run = item.run;
                const selected = selectedRunId === run.run_id;
                const latest = item.latest_checkpoint;
                const interventions = metadataEvents(run.metadata.interventions);
                return (
                  <div
                    key={run.run_id}
                    className={`border p-4 transition-colors ${selected ? "border-foreground/50 bg-secondary/20" : "border-border bg-secondary/10"}`}
                    onClick={() => setSelectedRunId(run.run_id)}
                  >
                    <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="mb-1 flex flex-wrap items-center gap-2">
                          <Badge variant={statusVariant(run.status)}>{run.status}</Badge>
                          <span className="break-all text-xs text-muted-foreground">{run.run_id}</span>
                        </div>
                        <div className="text-sm font-medium leading-relaxed">{run.goal}</div>
                        <div className="mt-1 flex flex-wrap gap-3 text-xs text-muted-foreground">
                          <span>profile: {run.profile_name}</span>
                          <span>stage: {run.current_stage_id ?? "-"}</span>
                          <span>unit: {run.current_unit_id ?? "-"}</span>
                          <span>updated: {run.updated_at}</span>
                        </div>
                      </div>
                      <div className="flex flex-wrap gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={(event) => {
                            event.stopPropagation();
                            controlRun(run.run_id, "pause", "Dashboard 暂停：等待人工检查或纠偏。");
                          }}
                          disabled={!!controlBusy || run.status === "paused" || run.status === "cancelled"}
                        >
                          {controlBusy === `${run.run_id}:pause` ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Pause className="h-4 w-4" />}
                          暂停
                        </Button>
                        <Button
                          variant="secondary"
                          size="sm"
                          onClick={(event) => {
                            event.stopPropagation();
                            controlRun(run.run_id, "resume", "Dashboard 恢复：按最新人工介入记录继续。");
                          }}
                          disabled={!!controlBusy || run.status === "running"}
                        >
                          {controlBusy === `${run.run_id}:resume` ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
                          恢复
                        </Button>
                        <Button
                          variant="destructive"
                          size="sm"
                          onClick={(event) => {
                            event.stopPropagation();
                            controlRun(run.run_id, "cancel", "Dashboard 取消：停止后续执行并保留当前证据。");
                          }}
                          disabled={!!controlBusy || run.status === "cancelled"}
                        >
                          {controlBusy === `${run.run_id}:cancel` ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Square className="h-4 w-4" />}
                          取消
                        </Button>
                      </div>
                    </div>

                    <div className="grid gap-3 lg:grid-cols-4">
                      {item.stages.map((stage) => (
                        <div key={stage.stage_id} className="border border-border bg-card/50 p-3">
                          <div className="mb-2 flex items-center justify-between gap-2">
                            <span className="text-xs font-medium uppercase tracking-[0.12em]">{stage.name}</span>
                            <Badge variant={statusVariant(stage.status)}>{stage.status}</Badge>
                          </div>
                          <div className="flex items-center gap-2 text-xs text-muted-foreground">
                            <Users className="h-3.5 w-3.5" />
                            {String(stage.metadata.owner ?? "-")}
                          </div>
                        </div>
                      ))}
                    </div>

                    <div className="mt-3 grid gap-3 lg:grid-cols-2">
                      <div className="border border-border bg-card/40 p-3">
                        <div className="mb-2 text-xs uppercase tracking-[0.14em] text-muted-foreground">Units</div>
                        <div className="flex flex-col gap-2">
                          {item.units.map((unit) => (
                            <div key={`${unit.stage_id}-${unit.unit_id}`} className="flex flex-wrap items-center justify-between gap-2 text-xs">
                              <span>{unit.stage_id}/{unit.unit_id} · {unit.name}</span>
                              <Badge variant={statusVariant(unit.status)}>{unit.status}</Badge>
                            </div>
                          ))}
                        </div>
                      </div>
                      <div className="border border-border bg-card/40 p-3">
                        <div className="mb-2 text-xs uppercase tracking-[0.14em] text-muted-foreground">Latest checkpoint</div>
                        <div className="text-xs leading-relaxed text-muted-foreground">
                          {latest ? (
                            <>
                              <div>{latest.stage_id}/{latest.unit_id} · {latest.status}</div>
                              <div className="mt-1 text-foreground/80">{latest.output_summary || latest.input_summary || "(no summary)"}</div>
                            </>
                          ) : (
                            "(none)"
                          )}
                        </div>
                      </div>
                    </div>

                    {interventions.length > 0 && (
                      <div className="mt-3 border border-warning/30 bg-warning/10 p-3">
                        <div className="mb-2 flex items-center gap-2 text-xs uppercase tracking-[0.14em] text-warning">
                          <AlertTriangle className="h-4 w-4" />
                          人工介入
                        </div>
                        <div className="flex flex-col gap-1 text-xs leading-relaxed">
                          {interventions.slice(-3).map((event, index) => (
                            <div key={`${run.run_id}-intervention-${index}`}>
                              {String(event.created_at ?? "")} · {String(event.message ?? event.note ?? "")}
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            <div className="border border-border bg-secondary/10 p-4">
              <div className="mb-2 text-xs uppercase tracking-[0.14em] text-muted-foreground">中途介入</div>
              <div className="mb-3 break-all text-xs text-muted-foreground">
                当前 run：{selectedRunId || "(未选择)"}
              </div>
              <textarea
                value={interventionText}
                onChange={(event) => setInterventionText(event.target.value)}
                rows={8}
                className="mb-3 min-h-36 w-full border border-border bg-card/60 px-3 py-2 text-sm outline-none focus:border-foreground/40"
                placeholder="例如：暂停实现，先补齐子代理状态回读；验收场景只作为能力测试，不要把业务功能当成 SelfExt 本体。"
              />
              <Button
                onClick={() => selectedRunId && controlRun(selectedRunId, "intervene", interventionText.trim())}
                disabled={!!controlBusy || !selectedRunId || !interventionText.trim()}
              >
                {controlBusy === `${selectedRunId}:intervene` ? <LoaderCircle className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
                写入介入记录
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 xl:grid-cols-2">
        <ConsoleBlock title="启动说明" text={workspace?.start_guide ?? ""} />
        <ConsoleBlock title="接管说明" text={workspace?.handoff ?? ""} />
      </div>
    </div>
  );
}

function InfoBlock({ label, value }: { label: string; value: string }) {
  return (
    <div className="border border-border bg-secondary/10 p-3">
      <div className="mb-1 text-[11px] uppercase tracking-[0.14em] text-muted-foreground">{label}</div>
      <div className="break-all text-sm leading-relaxed">{value}</div>
    </div>
  );
}

function statusVariant(status: string): "default" | "secondary" | "destructive" | "outline" | "success" | "warning" {
  const normalized = status.toLowerCase();
  if (["running", "verified", "done", "completed"].includes(normalized)) {
    return "success";
  }
  if (["paused", "pending", "checkpointed", "queued", "review"].includes(normalized)) {
    return "warning";
  }
  if (["failed", "cancelled", "error", "blocked"].includes(normalized)) {
    return "destructive";
  }
  return "outline";
}

function metadataEvents(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item));
}

function ConsoleBlock({ title, text }: { title: string; text: string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <pre className="max-h-[360px] overflow-auto whitespace-pre-wrap border border-border bg-secondary/15 p-3 text-xs leading-relaxed">
          {text || "(empty)"}
        </pre>
      </CardContent>
    </Card>
  );
}
