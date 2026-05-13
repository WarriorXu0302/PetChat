#!/usr/bin/env node
/**
 * CLI wrapper around the feishu parser.
 *
 * Usage:
 *   petchat-feishu-parse --file path --target-open-id ou_xxx --output report.md
 *   petchat-feishu-parse --file path --target-name 张三 --sender-map map.json --output report.md [--dump-normalized normalized.json]
 */

import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { parseFeishu, renderReport } from "./feishu.js";

function main(): void {
  const { values } = parseArgs({
    options: {
      file: { type: "string" },
      "target-open-id": { type: "string" },
      "target-name": { type: "string" },
      "sender-map": { type: "string" },
      output: { type: "string" },
      "dump-normalized": { type: "string" },
    },
    strict: true,
  });

  if (!values.file || !values.output) {
    console.error("缺少 --file 或 --output");
    process.exit(2);
  }
  if (!values["target-open-id"] && !values["target-name"]) {
    console.error("至少需要 --target-open-id 或 --target-name 其一");
    process.exit(2);
  }

  const raw = JSON.parse(fs.readFileSync(values.file, "utf-8"));
  let senderMap: Record<string, string> | undefined;
  if (values["sender-map"]) {
    senderMap = JSON.parse(fs.readFileSync(values["sender-map"], "utf-8"));
  }

  const { normalized, analysis } = parseFeishu(raw, {
    targetOpenId: values["target-open-id"],
    targetName: values["target-name"],
    senderMap,
  });

  const label = values["target-name"] ?? values["target-open-id"]!;
  const report = renderReport(values.file, label, analysis);

  fs.mkdirSync(path.dirname(path.resolve(values.output)), { recursive: true });
  fs.writeFileSync(values.output, report, "utf-8");

  if (values["dump-normalized"]) {
    fs.mkdirSync(path.dirname(path.resolve(values["dump-normalized"])), { recursive: true });
    fs.writeFileSync(
      values["dump-normalized"],
      JSON.stringify(normalized, null, 2),
      "utf-8",
    );
  }

  console.log(`已分析 ${analysis.totalMessages} 条, ta 占 ${analysis.targetMessages} 条`);
  console.log(`报告: ${values.output}`);
  if (values["dump-normalized"]) console.log(`规整数据: ${values["dump-normalized"]}`);
}

main();
