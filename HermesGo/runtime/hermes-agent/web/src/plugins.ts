import { useMemo, type ComponentType } from "react";
import type { PluginManifestResponse } from "@/lib/api";

export interface RegisteredPlugin {
  manifest: PluginManifestResponse;
  component: ComponentType;
}

export function usePlugins(): { plugins: RegisteredPlugin[] } {
  return useMemo(() => ({ plugins: [] as RegisteredPlugin[] }), []);
}
