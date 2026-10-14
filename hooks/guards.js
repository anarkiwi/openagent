// opencode plugin running the PreToolUse guards in this directory before a
// tool call, as Claude Code does from settings.json: each guard reads the
// Claude Code hook payload on stdin and prints a deny decision or nothing.
// A denial, or a guard that fails to run, aborts the call with its reason.
import { execFile } from "node:child_process"
import path from "node:path"

const GUARDS = {
  bash: ["format_check", "durable_comments", "worktree_guard"],
  write: ["min_comments"],
  edit: ["min_comments"],
}

function payload(tool, args, directory) {
  if (tool === "bash") {
    return {
      tool_name: "Bash",
      cwd: args.workdir ? path.resolve(directory, args.workdir) : directory,
      tool_input: { command: args.command ?? "" },
    }
  }
  if (tool === "write") {
    return {
      tool_name: "Write",
      tool_input: { file_path: args.filePath ?? "", content: args.content ?? "" },
    }
  }
  return {
    tool_name: "Edit",
    tool_input: { file_path: args.filePath ?? "", new_string: args.newString ?? "" },
  }
}

function run(python, script, event, options) {
  return new Promise((resolve) => {
    const child = execFile(python, [script], options, (error, stdout, stderr) => {
      resolve({ error, stdout, stderr })
    })
    child.stdin.on("error", () => {})
    child.stdin.end(event)
  })
}

function verdict(name, { error, stdout, stderr }) {
  if (error) {
    return `${name} guard failed to run: ${stderr.trim() || error.message}`
  }
  const out = stdout.trim()
  if (!out) return null
  const hook = JSON.parse(out).hookSpecificOutput
  return hook?.permissionDecision === "deny" ? hook.permissionDecisionReason : null
}

export const Guards = async ({ directory }) => {
  const dir = process.env.OPENAGENT_GUARDS ?? "/usr/local/lib/openagent/guards"
  const python = process.env.OPENAGENT_GUARD_PYTHON ?? "/usr/bin/python3"
  const options = {
    cwd: directory,
    env: { ...process.env, CLAUDE_PROJECT_DIR: directory },
    maxBuffer: 16 * 1024 * 1024,
  }
  return {
    "tool.execute.before": async (input, output) => {
      const names = GUARDS[input.tool]
      if (!names) return
      const event = JSON.stringify(payload(input.tool, output.args ?? {}, directory))
      const results = await Promise.all(
        names.map((name) => run(python, path.join(dir, `${name}.py`), event, options)),
      )
      const reasons = names.map((name, i) => verdict(name, results[i])).filter(Boolean)
      if (reasons.length) throw new Error(reasons.join("\n\n"))
    },
  }
}
