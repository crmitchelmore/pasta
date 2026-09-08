import assert from 'node:assert/strict';
import { test } from 'node:test';
import { incidentMarker, reportMonitorResult } from '../ci-monitor-incident.mjs';

function fixture(issues = []) {
  const calls = [];
  const github = { paginate: async () => issues, rest: { issues: {
    listForRepo() {}, create: async args => calls.push(['create', args]),
    update: async args => calls.push(['update', args]),
  } } };
  return { calls, options: { github, owner: 'owner', repo: 'repo', runId: 123, status: 'failure' } };
}

test('failure creates an assigned incident with actionable run evidence', async () => {
  const { options, calls } = fixture();
  await reportMonitorResult(options);
  assert.equal(calls[0][0], 'create');
  assert.deepEqual(calls[0][1].assignees, ['owner']);
  assert.match(calls[0][1].body, /actions\/runs\/123/);
});

test('repeated failure updates its incident and recovery closes it', async () => {
  const incident = { number: 8, user: { login: 'github-actions[bot]' }, body: incidentMarker };
  const { options, calls } = fixture([incident]);
  await reportMonitorResult(options);
  assert.equal(calls[0][0], 'update');
  assert.equal(calls[0][1].issue_number, 8);
  await reportMonitorResult({ ...options, status: 'success', runId: 124 });
  assert.equal(calls[1][1].state, 'closed');
  assert.match(calls[1][1].body, /actions\/runs\/124/);
});

test('healthy runs and cancellations leave unrelated owner issues alone', async () => {
  const { options, calls } = fixture([
    { number: 9, user: { login: 'owner' }, body: incidentMarker },
    { number: 10, user: { login: 'github-actions[bot]' }, body: 'Other work' },
    { number: 11, user: { login: 'github-actions[bot]' }, body: incidentMarker, pull_request: {} },
  ]);
  await reportMonitorResult({ ...options, status: 'success' });
  await reportMonitorResult({ ...options, status: 'cancelled' });
  assert.deepEqual(calls, []);
});

test('missing outcome evidence is rejected', async () => {
  const { options } = fixture();
  await assert.rejects(reportMonitorResult({ ...options, status: '' }), /Missing monitor/);
});
