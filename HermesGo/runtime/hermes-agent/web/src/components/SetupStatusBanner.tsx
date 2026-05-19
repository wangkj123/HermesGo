import { useEffect, useState, type ReactNode } from "react";
import { AlertCircle, CheckCircle2, Info } from "lucide-react";
import { api, type SetupStatusResponse } from "@/lib/api";

function Banner({
  className,
  children,
  icon,
}: {
  className: string;
  children: ReactNode;
  icon: ReactNode;
}) {
  return (
    <div className={`rounded-lg border px-4 py-3 text-sm flex gap-2 items-start ${className}`}>
      {icon}
      <span>{children}</span>
    </div>
  );
}

export function SetupStatusBanner() {
  const [status, setStatus] = useState<SetupStatusResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .getSetupStatus()
      .then(setStatus)
      .catch((e) => setError(String(e)));
  }, []);

  if (error) {
    return (
      <Banner
        className="border-amber-500/40 bg-amber-500/10 text-amber-100"
        icon={<AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />}
      >
        无法读取配置状态：{error}
      </Banner>
    );
  }

  if (!status) return null;

  const text = status.message || status.message_en || "";

  if (status.setup_state === "ready") {
    return (
      <Banner
        className="border-emerald-500/40 bg-emerald-500/10 text-emerald-50"
        icon={<CheckCircle2 className="h-4 w-4 mt-0.5 shrink-0 text-emerald-400" />}
      >
        {text}
      </Banner>
    );
  }

  if (status.setup_state === "needs_provider") {
    return (
      <Banner
        className="border-amber-500/50 bg-amber-500/15 text-amber-50"
        icon={<AlertCircle className="h-4 w-4 mt-0.5 shrink-0 text-amber-400" />}
      >
        {text}
      </Banner>
    );
  }

  return (
    <Banner
      className="border-sky-500/40 bg-sky-500/10 text-sky-50"
      icon={<Info className="h-4 w-4 mt-0.5 shrink-0 text-sky-400" />}
    >
      {text}
    </Banner>
  );
}
