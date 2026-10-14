// Tests for the guards plugin: each opencode tool call maps to the guard
// payload the Python guards expect, and a denial or a broken guard rejects.
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { before, test } from "node:test"

const HOOKS = path.dirname(new URL(import.meta.url).pathname)
const BAD_PY = "def f( a ):\n  return  a\n"
const GOOD_PY = "def f(a):\n    return a\n"

let repo

function git(...args) {
  execFileSync("git", ["-C", repo, ...args], { stdio: "pipe" })
}

function stage(name, content) {
  fs.writeFileSync(path.join(repo, name), content)
  git("add", name)
}

async function hook(directory = repo) {
  const { Guards } = await import("./guards.js")
  return (await Guards({ directory }))["tool.execute.before"]
}

function call(tool, args) {
  return [{ tool, sessionID: "s", callID: "c" }, { args }]
}

before(() => {
  process.env.OPENAGENT_GUARDS = HOOKS
  process.env.OPENAGENT_GUARD_PYTHON ??= "python3"
  process.env.GIT_CONFIG_GLOBAL = os.devNull
  process.env.GIT_CONFIG_SYSTEM = os.devNull
  repo = fs.mkdtempSync(path.join(os.tmpdir(), "guards-"))
  git("init", "--quiet", "--initial-branch=main")
  git("config", "user.email", "hook@example.invalid")
  git("config", "user.name", "Hook Test")
  git("commit", "--quiet", "--allow-empty", "-m", "root")
})

test("unformatted commit is denied with the formatter's fix", async () => {
  stage("bad.py", BAD_PY)
  await assert.rejects((await hook())(...call("bash", { command: "git commit -m wip" })), {
    message: /black bad\.py/,
  })
})

test("formatted commit passes", async () => {
  stage("bad.py", GOOD_PY)
  await (await hook())(...call("bash", { command: "git commit -m wip" }))
})

test("workdir is resolved against the session directory", async () => {
  fs.mkdirSync(path.join(repo, "sub"), { recursive: true })
  stage("sub/bad.py", BAD_PY)
  const run = await hook()
  await assert.rejects(run(...call("bash", { command: "git commit -m wip", workdir: "sub" })), {
    message: /bad\.py/,
  })
})

test("worktree outside the session repo is denied", async () => {
  await assert.rejects((await hook())(...call("bash", { command: "git worktree add ../x" })), {
    message: /worktrees must live inside/,
  })
})

test("every denying guard is reported", async () => {
  stage("note.py", "# added 2024-05-01\ndef f( a ):\n  return  a\n")
  const command = "git commit -m wip && git worktree add ../x"
  await assert.rejects((await hook())(...call("bash", { command })), ({ message }) => {
    assert.match(message, /black/)
    assert.match(message, /a date/)
    assert.match(message, /worktrees must live inside/)
    return true
  })
})

test("python write with consecutive comments is denied", async () => {
  const args = { filePath: "m.py", content: "# a\n# b\nx = 1\n" }
  await assert.rejects((await hook())(...call("write", args)), { message: /consecutive/ })
})

test("python edit with a terse replacement passes", async () => {
  const args = { filePath: "m.py", oldString: "x", newString: "y = 1  # radius\n" }
  await (await hook())(...call("edit", args))
})

test("tools without a guard pass untouched", async () => {
  await (await hook())(...call("read", { filePath: "/etc/passwd" }))
})

test("missing args pass as empty input", async () => {
  await (await hook())(...call("bash", undefined))
})

test("a guard that cannot run rejects rather than allowing", async () => {
  process.env.OPENAGENT_GUARDS = path.join(HOOKS, "missing")
  try {
    await assert.rejects((await hook())(...call("bash", { command: "ls" })), {
      message: /guard failed to run/,
    })
  } finally {
    process.env.OPENAGENT_GUARDS = HOOKS
  }
})

test("session outside any repo is unconstrained", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "norepo-"))
  await (await hook(dir))(...call("bash", { command: "git worktree add /elsewhere" }))
})
