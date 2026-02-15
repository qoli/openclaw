import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

const lastonePath = String(process.env.LASTONE_JSON_FILE || "").trim();

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

let requestCount = 0;
let totalMessages = 0;
let totalToolResults = 0;
let lastWriteError = "";

function writeLastone(event) {
  if (!lastonePath) {
    return;
  }
  try {
    const dir = path.dirname(lastonePath);
    fs.mkdirSync(dir, { recursive: true });
    const tmpPath = `${lastonePath}.tmp`;
    fs.writeFileSync(tmpPath, `${JSON.stringify(event, null, 2)}\n`, "utf8");
    fs.renameSync(tmpPath, lastonePath);
    lastWriteError = "";
  } catch (err) {
    const msg = String(err && err.message ? err.message : err);
    if (msg !== lastWriteError) {
      process.stderr.write(`WARN failed to write lastone.json: ${msg}\n`);
      lastWriteError = msg;
    }
  }
}

function countToolResultsFromMessages(messages) {
  let count = 0;
  for (const msg of messages) {
    if (msg && typeof msg === "object" && msg.role === "toolResult") {
      count += 1;
    }
  }
  return count;
}

function countToolResultsFromRoles(roles) {
  let count = 0;
  for (const role of roles) {
    if (role === "toolResult") {
      count += 1;
    }
  }
  return count;
}

rl.on("line", (line) => {
  const trimmed = String(line || "").trim();
  if (!trimmed) {
    return;
  }

  let event;
  try {
    event = JSON.parse(trimmed);
  } catch {
    return;
  }

  if (!event || event.stage !== "stream:context") {
    return;
  }

  writeLastone(event);

  const messages = Array.isArray(event.messages) ? event.messages : [];
  const messageRoles = Array.isArray(event.messageRoles) ? event.messageRoles : [];
  const messageCount =
    typeof event.messageCount === "number" && Number.isFinite(event.messageCount)
      ? event.messageCount
      : messages.length;

  let toolResultCount = countToolResultsFromMessages(messages);
  if (toolResultCount === 0 && messageRoles.length > 0) {
    toolResultCount = countToolResultsFromRoles(messageRoles);
  }

  requestCount += 1;
  totalMessages += messageCount;
  totalToolResults += toolResultCount;

  const reqPct = messageCount > 0 ? ((toolResultCount * 100) / messageCount).toFixed(1) : "0.0";
  const totalPct =
    totalMessages > 0 ? ((totalToolResults * 100) / totalMessages).toFixed(1) : "0.0";

  const provider = typeof event.provider === "string" ? event.provider : "-";
  const modelId = typeof event.modelId === "string" ? event.modelId : "-";
  const sessionKey = typeof event.sessionKey === "string" ? event.sessionKey : "-";
  const ts = typeof event.ts === "string" ? event.ts : "-";

  process.stdout.write(
    `INFO CACHE_TRACE req=${requestCount} ` +
      `messages=${messageCount} toolResult=${toolResultCount} reqToolResultPct=${reqPct}% ` +
      `totalMessages=${totalMessages} totalToolResult=${totalToolResults} totalToolResultPct=${totalPct}% ` +
      `provider=${provider} model=${modelId} session=${sessionKey} ts=${ts}\n`,
  );
});
