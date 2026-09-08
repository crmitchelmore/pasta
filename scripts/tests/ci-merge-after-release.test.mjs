import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertReleaseLanesIdle, verifyMergeWindow } from '../ci-merge-after-release.mjs';

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
    return path.includes('/git/ref/') ? { object: { sha: 'a' } } : { workflow_runs: [] };
  } };
  await verifyMergeWindow(options);
  assert.equal(seen.length, 22);
  for (const workflow of ['ci.yml', 'release.yml', 'release-ios.yml', 'deploy-landing-page.yml']) {
    assert.ok(seen.some(path => path.includes(`${workflow}/runs?status=queued`)));
  }
  let refs = 0;
  options.api = async path => path.includes('/git/ref/')
    ? { object: { sha: ++refs === 1 ? 'a' : 'b' } } : { workflow_runs: [] };
  await assert.rejects(verifyMergeWindow(options), /main advanced/);
});

test('unrelated PR CI does not block a merge; active main CI does', async () => {
  let branch = 'feature';
  const options = { repo: 'owner/repo', expectedMain: 'a', api: async path => {
    if (path.includes('/git/ref/')) return { object: { sha: 'a' } };
    return { workflow_runs: path.includes('ci.yml/runs?status=queued')
      ? [{ status: 'queued', head_branch: branch, event: 'push' }] : [] };
  } };
  await verifyMergeWindow(options);
  branch = 'main';
  await assert.rejects(verifyMergeWindow(options), /Merge blocked/);
});
