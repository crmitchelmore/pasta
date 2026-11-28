import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { incidentMarker, reportMainCI, suspectPulls } from '../ci-red-main.mjs';

const sha = n => String(n).repeat(40);
const run = (id, conclusion, minute, extra = {}) => ({
  id, conclusion, head_sha: sha(id), html_url: `https://github.com/o/r/actions/runs/${id}`,
  created_at: `2026-09-10T10:${String(minute).padStart(2, '0')}:00Z`,
  event: 'push', head_branch: 'main', workflow_id: 7, ...extra,
});
const bot = { login: 'github-actions[bot]' };

function fixture({ runs, issues = [], comments = [], jobs = [], commits = [] }) {
  const calls = [];
  const github = {
    paginate: async (method, args) => method === 'issues' ? issues : method === 'jobs' ? jobs : comments,
    rest: {
      actions: {
        listWorkflowRuns: async args => { calls.push(['runs', args]); return { data: { workflow_runs: runs } }; },
        listJobsForWorkflowRun: 'jobs',
      },
      repos: { compareCommitsWithBasehead: async args => { calls.push(['compare', args]); return { data: { commits: [...commits] } }; } },
      issues: {
        listForRepo: 'issues', listComments: 'comments',
        create: async args => { calls.push(['create', args]); return { data: { number: 50 } }; },
        update: async args => calls.push(['update', args]),
        createComment: async args => calls.push(['comment', args]),
      },
    },
  };
  return { calls, github };
}

test('a red main opens one assigned incident and notifies each suspect PR once', async () => {
  const green = run(1, 'success', 0);
  const red = run(2, 'failure', 5);
  const commits = [
    { sha: sha(4), commit: { message: 'fix: later (#12)' } },
    { sha: sha(3), commit: { message: 'feat: earlier (#11)\n\nbody (#99)' } },
  ];
  const { calls, github } = fixture({
    runs: [red, green], commits,
    jobs: [{ name: 'Build & Test', conclusion: 'success' }, { name: 'iOS E2E (XCUITest)', conclusion: 'failure' }],
    comments: [{ body: `<!-- pasta-red-main:${red.head_sha} -->` }],
  });
  assert.equal(await reportMainCI({ github, owner: 'o', repo: 'r', run: red }), 'red');
  const compare = calls.find(call => call[0] === 'compare');
  assert.equal(compare[1].basehead, `${green.head_sha}...${red.head_sha}`);
  const create = calls.find(call => call[0] === 'create')[1];
  assert.deepEqual(create.assignees, ['o']);
  assert.ok(create.body.startsWith(incidentMarker));
  assert.match(create.body, /Failed jobs: iOS E2E \(XCUITest\)\n/);
  assert.match(create.body, /Suspect PRs: #11, #12/);
  // The fixture already holds this run's comment, so a rerun never re-notifies.
  assert.ok(!calls.some(call => call[0] === 'comment'));
});

test('an open incident is updated, PRs get one comment, and the next green run closes it', async () => {
  const incident = { number: 8, user: bot, body: `${incidentMarker}\nold` };
  const red = run(3, 'timed_out', 9);
  const { calls, github } = fixture({
    runs: [red, run(1, 'success', 0)], issues: [incident],
    commits: [{ sha: sha(5), commit: { message: 'perf: thing (#20)' } }],
  });
  await reportMainCI({ github, owner: 'o', repo: 'r', run: red });
  assert.equal(calls.find(call => call[0] === 'update')[1].issue_number, 8);
  const comment = calls.find(call => call[0] === 'comment')[1];
  assert.equal(comment.issue_number, 20);
  assert.match(comment.body, /See #8/);

  const greenAgain = run(4, 'success', 20);
  const after = fixture({ runs: [greenAgain, red], issues: [incident] });
  assert.equal(await reportMainCI({ github: after.github, owner: 'o', repo: 'r', run: greenAgain }), 'closed');
  assert.equal(after.calls.find(call => call[0] === 'update')[1].state, 'closed');
});

test('stale, cancelled, PR and foreign runs change nothing; bad evidence fails closed', async () => {
  const late = run(2, 'failure', 5);
  const { calls, github } = fixture({ runs: [run(3, 'success', 10), late], issues: [{ number: 1, user: bot, body: incidentMarker }] });
  assert.equal(await reportMainCI({ github, owner: 'o', repo: 'r', run: late }), 'stale');
  for (const other of [run(5, 'cancelled', 30), run(6, 'failure', 30, { event: 'pull_request' }), run(7, 'failure', 30, { head_branch: 'feature' })]) {
    assert.equal(await reportMainCI({ github, owner: 'o', repo: 'r', run: other }), 'ignored');
  }
  assert.ok(!calls.some(call => ['create', 'update', 'comment'].includes(call[0])));
  await assert.rejects(reportMainCI({ github, owner: 'o', repo: 'r', run: { ...late, head_sha: 'abc' } }), /Missing CI run evidence/);

  const ownerIssue = fixture({ runs: [run(9, 'success', 40)], issues: [{ number: 2, user: { login: 'o' }, body: incidentMarker }] });
  assert.equal(await reportMainCI({ github: ownerIssue.github, owner: 'o', repo: 'r', run: run(9, 'success', 40) }), 'green');
});

test('suspects come from squash subjects only', () => {
  assert.deepEqual(suspectPulls([
    { commit: { message: 'a (#1)' } }, { commit: { message: 'b (#1)' } },
    { commit: { message: 'c\n\nrefs (#3)' } }, { commit: { message: 'Revert "x (#4)"' } },
  ]), [1]);
});

test('the responder workflow is wired to finished main CI only', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/main-ci-responder.yml', import.meta.url), 'utf8');
  assert.match(workflow, /workflow_run:\s*\n\s*workflows: \[CI\]\s*\n\s*types: \[completed\]\s*\n\s*branches: \[main\]/);
  assert.match(workflow, /github\.event\.workflow_run\.event == 'push'/);
  assert.match(workflow, /reportMainCI/);
  assert.doesNotMatch(workflow, /contents: write/);
});
