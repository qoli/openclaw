import fs from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { withTempHome } from "../../test/helpers/temp-home.js";
import {
  loadAndMaybeMigrateDoctorConfig,
  partitionDoctorConfigIssues,
} from "./doctor-config-flow.js";

describe("doctor config flow", () => {
  it("preserves invalid config for doctor repairs", async () => {
    await withTempHome(async (home) => {
      const configDir = path.join(home, ".openclaw");
      await fs.mkdir(configDir, { recursive: true });
      await fs.writeFile(
        path.join(configDir, "openclaw.json"),
        JSON.stringify(
          {
            gateway: { auth: { mode: "token", token: 123 } },
            agents: { list: [{ id: "pi" }] },
          },
          null,
          2,
        ),
        "utf-8",
      );

      const result = await loadAndMaybeMigrateDoctorConfig({
        options: { nonInteractive: true },
        confirm: async () => false,
      });

      expect((result.cfg as Record<string, unknown>).gateway).toEqual({
        auth: { mode: "token", token: 123 },
      });
    });
  });

  it("drops unknown keys on repair", async () => {
    await withTempHome(async (home) => {
      const configDir = path.join(home, ".openclaw");
      await fs.mkdir(configDir, { recursive: true });
      await fs.writeFile(
        path.join(configDir, "openclaw.json"),
        JSON.stringify(
          {
            bridge: { bind: "auto" },
            gateway: { auth: { mode: "token", token: "ok", extra: true } },
            agents: { list: [{ id: "pi" }] },
          },
          null,
          2,
        ),
        "utf-8",
      );

      const result = await loadAndMaybeMigrateDoctorConfig({
        options: { nonInteractive: true, repair: true },
        confirm: async () => false,
      });

      const cfg = result.cfg as Record<string, unknown>;
      expect(cfg.bridge).toBeUndefined();
      expect((cfg.gateway as Record<string, unknown>)?.auth).toEqual({
        mode: "token",
        token: "ok",
      });
    });
  });

  it("tolerates contextPruning.toolContext unknown-key issues", () => {
    const grouped = partitionDoctorConfigIssues([
      {
        path: "agents.defaults.contextPruning",
        message: 'Unrecognized key: "toolContext"',
      },
    ]);

    expect(grouped.tolerated).toHaveLength(1);
    expect(grouped.blocking).toHaveLength(0);
  });

  it("tolerates neverInjectConversationInfo root unknown-key issues", () => {
    const grouped = partitionDoctorConfigIssues([
      {
        path: "",
        message: 'Unrecognized key: "neverInjectConversationInfo"',
      },
    ]);

    expect(grouped.tolerated).toHaveLength(1);
    expect(grouped.blocking).toHaveLength(0);
  });

  it("keeps non-matching issues as blocking", () => {
    const grouped = partitionDoctorConfigIssues([
      {
        path: "agents.defaults.contextPruning",
        message: 'Unrecognized key: "unexpected"',
      },
      {
        path: "gateway.auth",
        message: "Required",
      },
    ]);

    expect(grouped.tolerated).toHaveLength(0);
    expect(grouped.blocking).toHaveLength(2);
  });
});
