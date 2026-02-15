import { describe, expect, it } from "vitest";
import type { TemplateContext } from "../templating.js";
import { buildInboundUserContextPrefix } from "./inbound-meta.js";

describe("buildInboundUserContextPrefix", () => {
  it("injects conversation info by default", () => {
    const ctx: TemplateContext = {
      ChatType: "direct",
      ConversationLabel: "Ronnie W. (@littleRonnie) id:731788051",
      Body: "hello",
    };

    const prefix = buildInboundUserContextPrefix(ctx);
    expect(prefix).toContain("Conversation info (untrusted metadata):");
    expect(prefix).toContain('"conversation_label":"Ronnie W. (@littleRonnie) id:731788051"');
  });

  it("skips conversation info when neverInjectConversationInfo is enabled", () => {
    const ctx: TemplateContext = {
      ChatType: "direct",
      ConversationLabel: "Ronnie W. (@littleRonnie) id:731788051",
      ReplyToBody: "previous message",
      Body: "hello",
    };

    const prefix = buildInboundUserContextPrefix(ctx, { neverInjectConversationInfo: true });
    expect(prefix).not.toContain("Conversation info (untrusted metadata):");
    expect(prefix).toContain("Replied message (untrusted, for context):");
  });
});
