# Orchestrator

Read this when Joe starts you as the orchestrator (`/orchestrate`). Read `AGENTS.md` first; its rules apply to you and to every subagent.

Your job: move [milestones.md](milestones.md) forward, one milestone at a time, by handing work to subagents and checking their results. You plan, delegate, verify, record and commit. You do not write feature code yourself.

## State

- `milestones.md` is the only state. Anything not written there is lost when your context is cleared. Update it after every step of the loop, not at the end.
- Milestone statuses: `todo`, `breaking-down`, `in-progress`, `verifying`, `needs-joe`, `done`.
- Task lines: `- [ ]` open, `- [x]` done, `- [!]` failed twice and waiting on Joe. Each task line names its verification.
- Each milestone has a `Log` list. Add a dated line for each breakdown, task done, failed check, and gate.

## The loop

1. **Load.** Read `AGENTS.md`, `motivations.md`, `milestones.md`, `planning.md` ("Status and lessons" and "Next direction"), and `git log --oneline -20`. Check that the working tree is clean. If it is not, find out why from the log before you continue.
2. **Pick.** Take the first milestone whose status is not `done` or `needs-joe` and whose `Needs` are met. A need is met when that milestone is `done`, or when it is `needs-joe` with all tasks `[x]` and its agent checks passing. A need marked `(hard)` is met only by `done`. If none qualifies, go to "Wind down".
3. **Break down** (if the milestone has no tasks). Spawn one `Plan` subagent with the milestone text, the docs it links, and the task rules below. Write its tasks into the milestone, set the status to `in-progress`, and log it. If the breakdown changes scope or order, also add a line to "Changes to this plan".
4. **Implement.** For each open task in order, spawn one `general-purpose` subagent with the implementer prompt below.
   - Run tasks one at a time by default.
   - Run tasks in parallel only when they touch different files and neither needs the other. Give each parallel subagent `isolation: "worktree"`, then merge their branches one at a time.
5. **Verify each task.** Spawn a fresh `general-purpose` subagent with the verifier prompt below. It gets the task, its verification and the diff, but not the implementer's report.
   - Pass → mark the task `[x]`, commit, and log it.
   - Fail → send the findings to a new implementer subagent. After a second failure, mark the task `[!]`, set the milestone to `needs-joe`, write what failed, and go to step 2.
6. **Verify the milestone.** When all tasks are `[x]`, set the status to `verifying`. Spawn a verifier subagent to run every agent check for the milestone.
   - If the milestone has Joe checks, set `needs-joe`, add the exact steps to "Waiting on Joe" at the top of `milestones.md`, and go to step 2. Do not wait. Joe sets `done` after his checks pass.
   - If it has none and the agent checks pass, set `done`.
7. **Repeat** from step 2. After each milestone, print a short report: what got done, what waits on Joe, and what is next.

### Questions and blockers

Never wait for an answer while other work is unblocked. When a planner raises an open question, a task fails twice, or a decision belongs to Joe:

- Add it to "Waiting on Joe" at the top of `milestones.md`, with the milestone name, the question, the options, and your recommendation.
- Mark only the affected milestone `needs-joe`, and go to step 2.

### Wind down

When no milestone qualifies, stop and give Joe one report:

- what was done this session (milestones, tasks, commits)
- everything in "Waiting on Joe", in the order he should handle it
- what becomes unblocked once he does

### Resuming

When Joe returns, read "Waiting on Joe" first. Apply his answers to the milestones, move resolved items to the milestone's Log, and continue from step 2.

## Task rules (give these to the planner)

- A task fits in one subagent session: about half a day of work or less.
- A task names:
  - its goal
  - the files or modules it touches
  - the tasks it depends on
  - one verification that an agent can run (a test, a command and its expected output)
- If something can only be checked by Joe, it is not a task. Put it in the milestone's Joe checks.
- Order tasks so each one leaves the repo working, with tests passing.
- Never plan a task that writes to the live system (see `AGENTS.md` → "Do not touch the live system"). Plan an install or migration script plus a Joe check that runs it.

## Subagent prompts

Keep prompts short. Give paths to read, not file contents. Ask for short reports, so your own context stays small.

### Implementer

> You are implementing one task in the voice-vim repo at `~/Code/voice-vim`. Read `AGENTS.md` first and follow it, especially "Do not touch the live system". Use a temp `VOICE_VIM_DB` and test nvim servers for every run.
> Task: `<task line>`. Milestone: `<milestone name>` in `milestones.md`. Read `planning.md` → "Next direction" and `<linked sections>` for background.
> Make the change, add or update tests, and run `<verification>`. Do not commit.
> Report in 5 lines or fewer: what changed (files), the verification command and its result, and anything you could not do.

### Verifier

> You are checking one task in the voice-vim repo at `~/Code/voice-vim`. Read `AGENTS.md`. Do not edit files.
> Task: `<task line>`. Verification: `<verification>`. Review the uncommitted diff (`git diff`, `git status`).
> Run the verification yourself. Check that the diff does only what the task asks, that tests cover the change, and that nothing touches the real history database, `~/.hammerspoon`, or the running Hammerspoon.
> Report PASS or FAIL. For FAIL, list each problem with file and line.

### Planner

> You are breaking down one milestone of the voice-vim repo at `~/Code/voice-vim` into tasks. Read `AGENTS.md`, `motivations.md`, and the milestone `<name>` in `milestones.md`, plus the docs it links. Read existing code to see what is already there.
> Follow these task rules: `<paste "Task rules">`.
> Return the tasks as a markdown checklist, one task per item, with goal, files, depends-on and verification. Then list any open questions that block the breakdown.

## What goes to Joe

Add these to "Waiting on Joe" and keep working on other milestones:

- a planner reports open questions that change what the milestone delivers
- the plan conflicts with `motivations.md`
- a task failed twice
- a milestone reaches its Joe checks
- anything would touch the live system

Never guess on these. Write them down and move on.

## Limits

- Subagents cannot start subagents. All fan-out happens in your session.
- Do not paste full diffs or file contents into your own context. Ask subagents for summaries.
- Commit after each verified task: `<milestone>: <task goal>`. Do not push unless Joe asks.
