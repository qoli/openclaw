import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadConfig: vi.fn(() => ({
    gateway: {
      auth: {
        token: "loopback-token",
      },
    },
  })),
  startBrowserControlServiceFromConfig: vi.fn(async () => true),
  dispatch: vi.fn(async () => ({ status: 200, body: { ok: true } })),
}));

vi.mock("../config/config.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../config/config.js")>();
  return {
    ...actual,
    loadConfig: mocks.loadConfig,
  };
});

vi.mock("./control-service.js", () => ({
  createBrowserControlContext: vi.fn(() => ({})),
  startBrowserControlServiceFromConfig: mocks.startBrowserControlServiceFromConfig,
}));

vi.mock("./routes/dispatcher.js", () => ({
  createBrowserRouteDispatcher: vi.fn(() => ({
    dispatch: mocks.dispatch,
  })),
}));

import { fetchBrowserJson } from "./client-fetch.js";

describe("fetchBrowserJson loopback auth", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    mocks.loadConfig.mockReset();
    mocks.loadConfig.mockReturnValue({
      gateway: {
        auth: {
          token: "loopback-token",
        },
      },
    });
    mocks.startBrowserControlServiceFromConfig.mockReset();
    mocks.startBrowserControlServiceFromConfig.mockResolvedValue(true);
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue({ status: 200, body: { ok: true } });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("adds bearer auth for loopback absolute HTTP URLs", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const res = await fetchBrowserJson<{ ok: boolean }>("http://127.0.0.1:18888/");
    expect(res.ok).toBe(true);

    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const headers = new Headers(init?.headers);
    expect(headers.get("authorization")).toBe("Bearer loopback-token");
  });

  it("does not inject auth for non-loopback absolute URLs", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await fetchBrowserJson<{ ok: boolean }>("http://example.com/");

    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const headers = new Headers(init?.headers);
    expect(headers.get("authorization")).toBeNull();
  });

  it("keeps caller-supplied auth header", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await fetchBrowserJson<{ ok: boolean }>("http://localhost:18888/", {
      headers: {
        Authorization: "Bearer caller-token",
      },
    });

    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const headers = new Headers(init?.headers);
    expect(headers.get("authorization")).toBe("Bearer caller-token");
  });

  it("surfaces relative-route request errors without connectivity wrapper", async () => {
    mocks.dispatch.mockResolvedValueOnce({
      status: 400,
      body: {
        error: 'Unknown ref "e156". Run a new snapshot and use a ref from that snapshot.',
      },
    });

    try {
      await fetchBrowserJson("/agent/act", {
        method: "POST",
      });
      throw new Error("expected fetchBrowserJson to throw");
    } catch (err) {
      const msg = String((err as Error).message ?? err);
      expect(msg).toContain('Unknown ref "e156"');
      expect(msg).not.toContain("Can't reach the OpenClaw browser control service");
    }
  });

  it("rewrites Playwright action timeouts into browser action guidance", async () => {
    mocks.dispatch.mockResolvedValueOnce({
      status: 500,
      body: {
        error:
          "Error: TimeoutError: locator.click: Timeout 8000ms exceeded. waiting for locator('[data-openclaw-ref=\"e207\"]')",
      },
    });

    try {
      await fetchBrowserJson("/act", {
        method: "POST",
      });
      throw new Error("expected fetchBrowserJson to throw");
    } catch (err) {
      const msg = String((err as Error).message ?? err);
      expect(msg).toContain('Browser action failed: click on ref "e207" timed out after 8000ms.');
      expect(msg).toContain("Capture a new snapshot and retry with a fresh ref/targetId.");
      expect(msg).not.toContain("Can't reach the OpenClaw browser control service");
    }
  });

  it("keeps connectivity timeout wrapper for request-level timeouts", async () => {
    mocks.dispatch.mockImplementationOnce(
      () =>
        new Promise(() => {
          // Intentionally unresolved.
        }),
    );

    await expect(
      fetchBrowserJson("/act", {
        method: "POST",
        timeoutMs: 25,
      }),
    ).rejects.toThrow("Can't reach the OpenClaw browser control service (timed out after 25ms)");
  });

  it("still wraps absolute-url network failures with connectivity hint", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("fetch failed");
      }),
    );

    await expect(fetchBrowserJson("http://127.0.0.1:18888/")).rejects.toThrow(
      "Can't reach the OpenClaw browser control service",
    );
  });
});
