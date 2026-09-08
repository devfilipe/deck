export const meta = {
  name: 'board',
  description: 'Run a deck board plan in a named workspace: one agent per task, groups in order, gates per group, review at the end',
  phases: [{ title: 'Read the plan' }, { title: 'Work' }, { title: 'Verify' }, { title: 'Review' }],
}

// deck decides what may run at the same time; this script runs it.
//
// The division matters. Claude Code already orchestrates agents, isolates them
// in worktrees, and runs them in parallel — none of that belongs in deck. What
// deck knows and Claude Code cannot is this workspace: that a change to the
// schema reaches the client, that two tasks touching the same chain must not
// run at once, and that a hardware target is an exclusive resource.
//
// The plan comes from `deck board plan --json`, read in the first phase.

// The workspace is named, never inferred. deck resolves a root by walking up
// from the working directory, which is right for a person in a terminal and
// dangerous here: a run started from a subdirectory of some other workspace
// would plan THAT board and start editing it. A workflow that spawns agents
// has to be told what it is working on.
const root = (typeof args === 'string' ? args : args?.root) ?? null
if (!root) {
  return {
    delivered: [],
    note:
      'no workspace given. Pass the root explicitly, e.g. args: {"root": "/path/to/workspace"} — ' +
      'this workflow will not guess which board to run.',
  }
}
const inRoot = `cd ${JSON.stringify(root)} &&`

phase('Read the plan')

const plan = await agent(
  `Run \`${inRoot} deck board plan --json\` and return its output verbatim as
   the object, including \`pending_decisions\` if deck reports any. If deck
   reports no descriptor or no tasks, return an empty groups array and say so in
   \`note\`. Do not invent tasks, and do not answer any decision.`,
  {
    label: 'plan',
    schema: {
      type: 'object',
      required: ['groups'],
      properties: {
        note: { type: 'string' },
        pending_decisions: { type: 'array', items: { type: 'object' } },
        groups: {
          type: 'array',
          items: {
            type: 'object',
            required: ['index', 'tasks'],
            properties: {
              index: { type: 'number' },
              parallel: { type: 'boolean' },
              tasks: { type: 'array', items: { type: 'object' } },
            },
          },
        },
      },
    },
  },
)

if (!plan || !plan.groups || plan.groups.length === 0) {
  return { delivered: [], note: plan?.note ?? 'deck produced no groups; nothing to run' }
}

// Stop before spending anything. An agent inside a run has no channel to a
// person: told to ask, it has nowhere to ask, and every task blocks before its
// first edit — which is exactly what the first run of this workflow did. So the
// decisions are collected here and handed back to the session that has someone
// attached. This is the ground wire, and it is deliberate rather than a
// failure to automate.
const pending = plan.pending_decisions ?? []
if (pending.length > 0) {
  return {
    delivered: [],
    pending_decisions: pending,
    note:
      `${pending.length} decision(s) must be answered before this board can run unattended. ` +
      `Put them to the operator, record each with \`deck toggle set --at workspace <id> <value>\`, ` +
      `then resume. Nothing was spawned and nothing was spent.`,
  }
}

const done = []

// Groups run in order — that ordering is the conflict resolution. Within a
// group, tasks are independent by construction, so they run together.
for (const group of plan.groups) {
  phase('Work')

  const results = await parallel(
    group.tasks.map(task => () =>
      agent(
        `Task ${task.id}: ${task.title}

         It touches these repositories, in this order: ${(task.order ?? task.repos).join(' -> ')}
         Work only in those. The order is the impact chain: a change upstream
         forces the ones after it, so do not skip a step because the build passes.

         The workspace is ${root}. Work there and nowhere else.

         Before editing anything:
           cd ${root}
           deck mount --task ${task.id} --repos ${(task.repos ?? []).join(',')}
           deck toggle ask-plan --stage plan --files <files you will touch>

         Every decision the catalog foresaw was answered before this run started,
         so ask-plan should come back empty. Two things can still happen, and
         they are not the same:

         - A decision THIS task owns (\`decides:\` on the board item). It is
           yours to make in context — take it, record it with
           \`deck toggle set --at workspace <id> <value>\`, and say in your
           report why.
         - A question nobody foresaw. Write it down and keep working:
           \`deck ask new "<question>" --task ${task.id} --context "<what a
           person needs to decide it>"\`. Nothing waits on it. Say what you did
           in the meantime and what would change if the answer goes the other
           way.

         Do not stall on a question, and do not silently decide one that is not
         yours.

         When the work is done:
           deck gate run --task ${task.id}
           deck unmount --task ${task.id}
           deck bundle --task ${task.id} --write
           deck board done ${task.id} --yes

         The bundle comes first on purpose: \`done\` only checks that the gates
         passed, the bundle checks everything else, and anything it finds is
         cheaper to fix before the task is closed than after.

         \`done\` refuses unless the ladder ran and passed under that name, which
         is the point: closing is a claim about verification. If it refuses, say
         so in your report rather than forcing it. Leave the change committed in
         the repositories you touched. Do not push.

         \`bundle\` is what the reviewer will read instead of your report. Run it
         last, read it, and carry its verdict into yours — if it says NOT READY,
         your report says so too, whatever else went well. Name ${task.id} in
         every commit message, so the bundle attributes the change to the task
         rather than to the window it happened in.

         Two fields, and they are not the same thing. \`blocked\` means the work
         was NOT done and why. Anything you want a person to decide, while the
         work still got done, goes in \`questions\` — the run stays counted as
         work, and its gates still run.`,
        {
          label: `task:${task.id}`,
          phase: 'Work',
          // Deliberately not `isolation: 'worktree'`. A worktree is made of one
          // repository, and a deck workspace is usually several — its root is
          // often not a checkout at all. Isolating the wrong repository is
          // worse than not isolating: the agents would all work in a copy of
          // whatever repo the session happened to sit in. Grouping is what
          // keeps concurrent tasks apart here, and it is the guarantee deck
          // actually offers.
          schema: {
            type: 'object',
            required: ['id', 'summary', 'repos_changed'],
            properties: {
              id: { type: 'string' },
              summary: { type: 'string' },
              repos_changed: { type: 'array', items: { type: 'string' } },
              blocked: { type: 'string' },
              questions: { type: 'array', items: { type: 'string' } },
            },
          },
        },
      ),
    ),
  )

  // A task that changed code is verified, whatever else it reported. The first
  // version filtered on `blocked` alone, and an agent that finished its work and
  // raised a question for a later rung was dropped from the group — so the gates
  // ran over one repository instead of two and nothing said the other had been
  // left out. Silent partial verification is the failure this whole tool exists
  // to prevent.
  const worked = results.filter(Boolean).filter(r => (r.repos_changed ?? []).length > 0 || !r.blocked)
  const stalled = results.filter(Boolean).filter(r => r.blocked && (r.repos_changed ?? []).length === 0)
  const raised = results.filter(Boolean).flatMap(r => (r.questions ?? []).map(q => ({ task: r.id, question: q })))

  // Gates run once over the group, not once per task. What matters is whether
  // the integrated state holds, and a per-task run would say nothing about that.
  phase('Verify')
  const verdict = await agent(
    `The following tasks finished in this group: ${worked.map(r => r.id).join(', ')}.

     In ${root}, run \`deck gate run --task group-${group.index}\` over the
     repositories they changed: ${[...new Set(worked.flatMap(r => r.repos_changed ?? []))].join(', ')}.

     Report the ladder exactly as deck reports it. A gate that did not run is
     not a gate that passed — carry the reason through verbatim.`,
    {
      label: `gates:group-${group.index}`,
      phase: 'Verify',
      schema: {
        type: 'object',
        required: ['level_reached', 'passed', 'failed', 'not_run'],
        properties: {
          level_reached: { type: 'string' },
          passed: { type: 'array', items: { type: 'string' } },
          failed: { type: 'array', items: { type: 'string' } },
          not_run: { type: 'array', items: { type: 'object' } },
          evidence: { type: 'string' },
        },
      },
    },
  )

  done.push({ group: group.index, tasks: worked, blocked: stalled, questions: raised, verdict })
}

// The last decision is a person's. This phase prepares it and stops.
phase('Review')

const review = await agent(
  `Here is what the run produced:

   ${JSON.stringify(done, null, 2)}

   That is what the agents SAID. What deck RECORDED is in ${root}: read
   \`deck bundle --task <id>\` for each task above, or the markdown each agent
   left under .deck/bundles/. It is derived from the gate record, the impact
   graph, the toggle layers and git — so where the two disagree, the bundle is
   the one to believe, and the disagreement is itself worth reporting.

   This is a review of the DELIVERY, not of the code. Claude Code already has a
   code reviewer and a security reviewer, and you cannot invoke them from here —
   so do not attempt one and do not imply you performed one.

   Write what a human needs to decide, per task, between delivering, refactoring
   and discarding: what changed, which rung of the ladder its group reached,
   what went unverified and why, and which decisions were taken along the way.
   Be plain about anything the agents did not check.

   End by naming the reviews that have not happened, so the person runs them:
   \`/code-review\` for the diff, \`/security-review\` where the change warrants it.

   Do not push anything. That decision is not yours.`,
  {
    label: 'review',
    phase: 'Review',
    schema: {
      type: 'object',
      required: ['recommendation'],
      properties: {
        reviews_not_run: { type: 'array', items: { type: 'string' } },
        recommendation: {
          type: 'array',
          items: {
            type: 'object',
            required: ['id', 'decision', 'why'],
            properties: {
              id: { type: 'string' },
              decision: { type: 'string', enum: ['deliver', 'refactor', 'discard'] },
              why: { type: 'string' },
            },
          },
        },
        unverified: { type: 'array', items: { type: 'string' } },
      },
    },
  },
)

return { groups: done, review }
