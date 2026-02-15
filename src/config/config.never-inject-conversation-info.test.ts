import { describe, expect, it } from "vitest";
import { validateConfigObject } from "./config.js";

describe("neverInjectConversationInfo config", () => {
  it("accepts neverInjectConversationInfo", () => {
    const res = validateConfigObject({
      neverInjectConversationInfo: true,
    });

    expect(res.ok).toBe(true);
    expect(res.config.neverInjectConversationInfo).toBe(true);
  });
});
