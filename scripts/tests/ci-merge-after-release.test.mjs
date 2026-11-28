import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { test } from 'node:test';
import { assertMainGreen, assertReleaseLanesIdle, publicationWorkflows, verifyMergeWindow } from '../ci-merge-after-release.mjs';

const greenMain = { workflow_runs: [{ conclusion: 'success', head_sha: 'a' }] };

test('CLI supplies a clean squash body instead of inheriting historical commit messages', t => {
  const root = mkdtempSync(join(tmpdir(), 'pasta-merge-message-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const log = join(root, 'calls.jsonl');
  writeFileSync(join(root, 'gh'), `#!/usr/bin/env node
const { appendFileSync } = require('node:fs');
const args = process.argv.slice(2);
appendFileSync(process.env.CALL_LOG, JSON.stringify(args) + '\\n');
if (args[0] === 'api') {
  if (args[1].includes('/git/ref/')) console.log(JSON.stringify({ object: { sha: 'main-sha' } }));
  else if (args[1].includes('/contents/')) console.log(JSON.stringify(${JSON.stringify(publicationWorkflows.map(name => ({ name })))}));
  else if (args[1].includes('status=completed')) console.log(JSON.stringify({ workflow_runs: [{ conclusion: process.env.MAIN_CONCLUSION, head_sha: 'main-sha' }] }));
  else if (args[1].includes('/runs?')) console.log(JSON.stringify({ workflow_runs: [] }));
  else throw new Error('Unexpected API request');
} else if (args[0] === 'pr' && args[1] === 'view') {
  console.log(JSON.stringify({ headRefOid: 'pr-head', baseRefName: 'main', isDraft: false, reviewDecision: 'APPROVED' }));
} else if (args[0] === 'pr' && args[1] === 'checks') {
  if (!args.includes('--required')) throw new Error('Required checks missing');
} else if (args[0] === 'pr' && args[1] === 'merge') {
  const bodyIndex = args.indexOf('--body');
  const body = bodyIndex === -1 ? 'Historical message [skip ci]' : args[bodyIndex + 1];
  console.log(body);
} else throw new Error('Unexpected gh command');
`, { mode: 0o755 });
  const options = {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${root}${delimiter}${process.env.PATH}`, GITHUB_REPOSITORY: 'owner/repo', CALL_LOG: log, MAIN_CONCLUSION: 'success' },
  };
  const script = resolve('scripts/ci-merge-after-release.mjs');
  const output = execFileSync(process.execPath, [script, '42'], options);
  const calls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  const merge = calls.find(args => args[0] === 'pr' && args[1] === 'merge');
  assert.deepEqual(merge, [
    'pr', 'merge', '42', '--repo', 'owner/repo', '--squash', '--match-head-commit', 'pr-head',
    '--body', 'Merged after required PR checks passed and publication lanes were idle.',
  ]);
  assert.doesNotMatch(output, /\[skip ci\]/i);
  assert.ok(calls.findIndex(args => args[1] === 'checks') < calls.indexOf(merge));
  assert.equal(calls.filter(args => args[0] === 'api' && args[1].includes('/runs?')).length, 36);
  assert.equal(calls.filter(args => args[0] === 'api' && args[1].includes('/git/ref/')).length, 3);

  writeFileSync(log, '');
  execFileSync(process.execPath, [script, '42', '--check'], options);
  const checkCalls = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.ok(!checkCalls.some(args => args[0] === 'pr' && args[1] === 'merge'));

  writeFileSync(log, '');
  const red = { ...options, env: { ...options.env, MAIN_CONCLUSION: 'failure' }, stdio: 'pipe' };
  assert.throws(() => execFileSync(process.execPath, [script, '42'], red), /main CI is failure/);
  assert.ok(!readFileSync(log, 'utf8').includes('"merge"'));
  execFileSync(process.execPath, [script, '42', '--fix-forward'], red);
  assert.ok(readFileSync(log, 'utf8').includes('"merge"'));
});

test('a red main blocks merges until fixed; cancelled runs are not verdicts', async () => {
  const api = runs => async () => ({ workflow_runs: runs });
  await assertMainGreen({ repo: 'owner/repo', api: api([{ conclusion: 'cancelled' }, { conclusion: 'success' }]) });
  for (const conclusion of ['failure', 'timed_out', 'startup_failure', 'action_required']) {
    const runs = [{ conclusion: 'cancelled' }, { conclusion, head_sha: 'b' }, { conclusion: 'success' }];
    await assert.rejects(assertMainGreen({ repo: 'owner/repo', api: api(runs) }), /Merge blocked: main CI is/);
    await assertMainGreen({ repo: 'owner/repo', api: api(runs), allowRedMain: true });
  }
  await assert.rejects(assertMainGreen({ repo: 'owner/repo', api: api([]) }), /No completed main CI verdict/);
  await assert.rejects(assertMainGreen({ repo: 'owner/repo', api: async () => ({}) }), /Missing main CI evidence/);
});

test('queued, waiting, pending and running releases block every subsequent merge', () => {
  for (const status of ['queued', 'waiting', 'pending', 'in_progress', 'requested']) {
    assert.throws(() => assertReleaseLanesIdle([{ status, name: 'Release' }]), /Merge blocked/);
  }
  assert.doesNotThrow(() => assertReleaseLanesIdle([{ status: 'completed', conclusion: 'failure' }]));
});

test('all lanes and statuses are checked, and an advancing main fails closed', async () => {
  const seen = [];
  const options = { repo: 'owner/repo', expectedMain: 'a', api: async path => {
    seen.push(path);
    if (path.includes('status=completed')) return greenMain;
    return path.includes('/git/ref/') ? { object: { sha: 'a' } } : { workflow_runs: [] };
  } };
  await verifyMergeWindow(options);
  assert.equal(seen.length, 38);
  for (const workflow of ['ci.yml', 'release.yml', 'release-ios.yml', 'deploy-landing-page.yml', 'alpha-release.yml', 'prepare-stable.yml', 'publish-stable.yml']) {
    assert.ok(seen.some(path => path.includes(`${workflow}/runs?status=queued`)));
  }
  let refs = 0;
  options.api = async path => path.includes('status=completed') ? greenMain : path.includes('/git/ref/')
    ? { object: { sha: ++refs === 1 ? 'a' : 'b' } } : { workflow_runs: [] };
  await assert.rejects(verifyMergeWindow(options), /main advanced/);
});

test('unrelated PR CI does not block a merge; active main CI does', async () => {
  let branch = 'feature';
  const options = { repo: 'owner/repo', expectedMain: 'a', api: async path => {
    if (path.includes('/git/ref/')) return { object: { sha: 'a' } };
    if (path.includes('status=completed')) return greenMain;
    return { workflow_runs: path.includes('ci.yml/runs?status=queued')
      ? [{ status: 'queued', head_branch: branch, event: 'push' }] : [] };
  } };
  await verifyMergeWindow(options);
  branch = 'main';
  await assert.rejects(verifyMergeWindow(options), /Merge blocked/);
});
