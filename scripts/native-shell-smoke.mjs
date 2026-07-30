import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const helper = resolve(root, "runtime-distribution", "window-capture", "win-x64", "HybridWindowCapture.exe");
const checksumPath = `${helper}.sha256`;
const helperBytes = await readFile(helper);
const expectedText = (await readFile(checksumPath, "utf8")).trim();
const expected = /^([a-f0-9]{64})\s+HybridWindowCapture\.exe$/iu.exec(expectedText)?.[1]?.toLowerCase();
assert.ok(expected, "Native helper checksum file is malformed.");
assert.equal(createHash("sha256").update(helperBytes).digest("hex"), expected);

const temporaryRoot = await mkdtemp(join(tmpdir(), "hybrid-native-shell-"));
const evidencePath = join(temporaryRoot, "containment.json");
const powershell = join(process.env.SystemRoot ?? process.env.WINDIR ?? "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
const wrapper = [
  "$utf8=[Text.UTF8Encoding]::new($false)",
  "[Console]::InputEncoding=$utf8",
  "[Console]::OutputEncoding=$utf8",
  "$script=[Console]::In.ReadToEnd()",
  "& ([ScriptBlock]::Create($script))",
].join("; ");
const previousConfiguredHelper = process.env.CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER;
process.env.CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER = helper;

try {
  const result = await new Promise((resolveResult, reject) => {
    const child = spawn(helper, [
      "shell-host",
      "--powershell", powershell,
      "--cwd", temporaryRoot,
      "--containment-evidence", evidencePath,
      "--",
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-Command", wrapper,
    ], {
      cwd: root,
      env: {
        ...process.env,
        CHATGPT_HYBRID_SHELL_JOB_ID: "shell_0123456789abcdef0123456789abcdef",
      },
      windowsHide: true,
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("Native shell-host smoke timed out."));
    }, 20_000);
    child.once("close", (exitCode) => {
      clearTimeout(timer);
      resolveResult({ exitCode, stdout, stderr });
    });
    child.stdin.end("Write-Output ('NATIVE_HOST_PID=' + $env:CHATGPT_HYBRID_SHELL_OWNER_PROCESS_ID)\n");
  });
  assert.equal(result.exitCode, 0, result.stderr);
  const outputPid = Number(/NATIVE_HOST_PID=(\d+)/u.exec(result.stdout)?.[1]);
  assert.ok(Number.isInteger(outputPid) && outputPid > 0, result.stdout);
  const evidence = JSON.parse(await readFile(evidencePath, "utf8"));
  assert.deepEqual({
    kind: evidence.kind,
    host: evidence.host,
    enforced: evidence.enforced,
    jobId: evidence.jobId,
    processId: evidence.processId,
  }, {
    kind: "windows_job_object_kill_on_close",
    host: "native_aot_shell_host",
    enforced: true,
    jobId: "shell_0123456789abcdef0123456789abcdef",
    processId: outputPid,
  });

  const { getShellOutput, getShellStatus, startShellJob } = await import("../dist/shell.js");
  const projectRoot = join(temporaryRoot, "project");
  await mkdir(projectRoot, { recursive: true });
  const profile = Object.freeze({
    id: "native-shell-smoke",
    displayName: "Native Shell Smoke",
    appName: "Native Shell Smoke",
    serverName: "native-shell-smoke",
    permissionPreset: "workstation",
    defaultWorkingDirectoryRelative: ".",
    httpPort: 23997,
    bootstrapFiles: Object.freeze([]),
    identityMarkers: Object.freeze([]),
    primaryRoot: projectRoot,
  });
  const context = Object.freeze({
    profile,
    primaryRoot: projectRoot,
    defaultWorkingDirectory: projectRoot,
    engineRoot: root,
    managedProjectRoots: Object.freeze([{ profileId: profile.id, primaryRoot: projectRoot }]),
  });
  const descendantStartedPath = join(temporaryRoot, "descendant-started.txt");
  const forbiddenPath = join(temporaryRoot, "descendant-outlived-host.txt");
  const quote = (value) => value.replaceAll("'", "''");
  const descendantScript = [
    `Set-Content -LiteralPath '${quote(descendantStartedPath)}' -Value $PID`,
    "Start-Sleep -Seconds 2",
    `Set-Content -LiteralPath '${quote(forbiddenPath)}' -Value 'escaped'`,
  ].join("\n");
  const encodedDescendant = Buffer.from(descendantScript, "utf16le").toString("base64");
  const command = [
    `$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand','${encodedDescendant}') -PassThru`,
    "$deadline = [DateTime]::UtcNow.AddSeconds(15)",
    `while (-not (Test-Path -LiteralPath '${quote(descendantStartedPath)}') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }`,
    `if (-not (Test-Path -LiteralPath '${quote(descendantStartedPath)}')) { throw 'descendant did not start' }`,
    "Write-Output 'INTEGRATED_NATIVE_OK'",
  ].join("\n");
  const started = await startShellJob({ context, cwd: temporaryRoot, command, timeoutMs: 30_000 });
  const deadline = Date.now() + 20_000;
  let status = getShellStatus(context, started.id);
  while (status.status === "running" && Date.now() < deadline) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
    status = getShellStatus(context, started.id);
  }
  assert.equal(status.status, "completed");
  assert.equal(status.containmentEnforced, true);
  assert.equal(status.trackingState, "archived_terminal");
  const integratedEvidence = JSON.parse(await readFile(status.containmentEvidencePath, "utf8"));
  assert.equal(integratedEvidence.host, "native_aot_shell_host");
  assert.equal(integratedEvidence.processId, status.processId);
  const ownerEvidence = JSON.parse(await readFile(status.ownerEvidencePath, "utf8"));
  assert.equal(ownerEvidence.processId, status.processId);
  assert.equal(ownerEvidence.jobId, started.id);
  const integratedOutput = await getShellOutput({
    context,
    id: started.id,
    stdoutOffset: 0,
    stderrOffset: 0,
    maxCharacters: 20_000,
  });
  assert.match(integratedOutput.stdout.text, /INTEGRATED_NATIVE_OK/u);
  await new Promise((resolveWait) => setTimeout(resolveWait, 3_000));
  await assert.rejects(access(forbiddenPath));
  console.log(`NativeAOT shell-host smoke passed: direct PID ${outputPid}, integrated PID ${status.processId}.`);
} finally {
  if (previousConfiguredHelper === undefined) delete process.env.CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER;
  else process.env.CHATGPT_HYBRID_WINDOW_CAPTURE_HELPER = previousConfiguredHelper;
  await rm(temporaryRoot, { recursive: true, force: true });
}
