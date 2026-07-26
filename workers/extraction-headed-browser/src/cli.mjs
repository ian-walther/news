import { extractFromRequest } from "./extractor.mjs";

export async function main() {
  try {
    const input = await readStdin();
    const request = JSON.parse(input);
    const result = await extractFromRequest(request);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    const result = {
      schema_version: 1,
      implementation: "extraction.headed_browser",
      status: "failed",
      failure_kind: "worker_error",
      retryable: false,
      message: error instanceof Error ? error.message : String(error),
      debug_metadata: {}
    };

    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exitCode = 1;
  }
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let input = "";

    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => {
      input += chunk;
    });
    process.stdin.on("end", () => resolve(input));
    process.stdin.on("error", reject);
  });
}
