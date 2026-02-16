import type { RuntimeEnv } from "../../runtime.js";
import { loadModelCatalog } from "../../agents/model-catalog.js";
import { modelKey } from "../../agents/model-selection.js";
import { readConfigFileSnapshot } from "../../config/config.js";
import { logConfigUpdated } from "../../config/logging.js";
import { resolveModelTarget, updateConfig } from "./shared.js";

export async function modelsSetCommand(modelRaw: string, runtime: RuntimeEnv) {
  // 1. Read config and resolve the model reference
  const snapshot = await readConfigFileSnapshot();
  if (!snapshot.valid) {
    const issues = snapshot.issues.map((i) => `- ${i.path}: ${i.message}`).join("\n");
    throw new Error(`Invalid config at ${snapshot.path}\n${issues}`);
  }
  const cfg = snapshot.config;
  const resolved = resolveModelTarget({ raw: modelRaw, cfg });
  const key = `${resolved.provider}/${resolved.model}`;

  // 2. Validate against catalog (skip when catalog is empty — initial setup)
  const catalog = await loadModelCatalog({ config: cfg });
  if (catalog.length > 0) {
    const catalogKeys = new Set(catalog.map((e) => modelKey(e.provider, e.id)));
    if (!catalogKeys.has(key)) {
      throw new Error(
        `Unknown model: ${key}\nModel not found in catalog. Run "openclaw models list" to see available models.`,
      );
    }
  }

  // 3. Track whether this is a new entry
  const isNewEntry = !cfg.agents?.defaults?.models?.[key];

  // 4. Update config
  const updated = await updateConfig((c) => {
    const nextModels = { ...c.agents?.defaults?.models };
    if (!nextModels[key]) {
      nextModels[key] = {};
    }
    const existingModel = c.agents?.defaults?.model as
      | { primary?: string; fallbacks?: string[] }
      | undefined;
    return {
      ...c,
      agents: {
        ...c.agents,
        defaults: {
          ...c.agents?.defaults,
          model: {
            ...(existingModel?.fallbacks ? { fallbacks: existingModel.fallbacks } : undefined),
            primary: key,
          },
          models: nextModels,
        },
      },
    };
  });

  // 5. Warn and log
  if (isNewEntry) {
    runtime.log(
      `Warning: "${key}" had no entry in models config. Added with empty config (no provider routing).`,
    );
  }
  logConfigUpdated(runtime);
  runtime.log(`Default model: ${updated.agents?.defaults?.model?.primary ?? modelRaw}`);
}
