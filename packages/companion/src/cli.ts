#!/usr/bin/env node
/**
 * Minimal CLI for smoke-testing the backend switch.
 *
 *   petchat-companion list
 *   petchat-companion chat <slug> --source distilled|feishu
 *   petchat-companion register-feishu <slug> <name> <chat_id>
 *
 * Exit chat with empty line, Ctrl+D, or /quit.
 */

import path from "node:path";
import readline from "node:readline";
import { BackendRegistry } from "./backend/registry.js";

const COMPANION_ROOT = path.resolve(process.cwd(), "packages/companion");

function print(s: string): void {
  process.stdout.write(s);
}

async function chatLoop(slug: string, source: "distilled" | "feishu"): Promise<void> {
  const reg = new BackendRegistry(COMPANION_ROOT);
  let backend;
  try {
    backend = reg.get(slug, source);
  } catch (err) {
    console.error(`启动后端失败: ${(err as Error).message}`);
    process.exit(1);
  }

  const meta = backend.metadata;
  console.log(`--- ${meta.displayName} (${meta.source}) ---`);
  if (meta.notice) console.log(meta.notice);
  console.log("最近历史:");
  for (const m of await backend.history(20)) {
    const tag = m.role === "user" ? "你" : meta.displayName;
    console.log(`  [${tag}] ${m.content}`);
  }
  console.log("(空行 / Ctrl+D 退出)");

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  rl.setPrompt("> ");
  rl.prompt();
  for await (const raw of rl) {
    const line = raw.trim();
    if (!line || line === "/quit" || line === "/exit") break;
    print(`  [${meta.displayName}] `);
    for await (const chunk of backend.send(line)) print(chunk);
    print("\n");
    rl.prompt();
  }
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  const reg = new BackendRegistry(COMPANION_ROOT);

  if (cmd === "list") {
    for (const c of reg.listContacts()) {
      const flags: string[] = [];
      if (c.hasDistilled) flags.push("distilled");
      if (c.hasFeishu) flags.push("feishu");
      console.log(`- ${c.slug.padEnd(20)} ${(c.name ?? "").padEnd(16)} [${flags.join(",") || "empty"}]`);
    }
    return;
  }

  if (cmd === "register-feishu") {
    const [slug, name, chatId] = rest;
    if (!slug || !name || !chatId) {
      console.error("用法: register-feishu <slug> <name> <chat_id>");
      process.exit(2);
    }
    reg.registerFeishu(slug, name, chatId);
    console.log(`已绑定 ${slug} → chat_id=${chatId}`);
    return;
  }

  if (cmd === "chat") {
    const [slug] = rest;
    const sourceIdx = rest.indexOf("--source");
    const source = (sourceIdx >= 0 ? rest[sourceIdx + 1] : "distilled") as
      | "distilled"
      | "feishu";
    if (!slug) {
      console.error("用法: chat <slug> [--source distilled|feishu]");
      process.exit(2);
    }
    await chatLoop(slug, source);
    return;
  }

  console.error("用法: list | chat <slug> [--source ...] | register-feishu <slug> <name> <chat_id>");
  process.exit(2);
}

main();
