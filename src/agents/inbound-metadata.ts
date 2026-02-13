export const INBOUND_METADATA_BLOCK_REGEX =
  /(?:Conversation info|Sender|Thread starter|Replied message|Forwarded message context|Chat history since last reply) \(untrusted(?: metadata|,\s+for\s+context)\):\n```json\n[\s\S]*?\n```\n*/g;
