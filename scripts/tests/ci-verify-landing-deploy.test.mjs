import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { verifyLandingDeploy, verifyReleasePublication, verifyManifestPublication } from '../ci-verify-landing-deploy.mjs';

const sha = 'a'.repeat(40);
function fixture() {
  const run = { id: 123, head_sha: sha, head_branch: 'main', event: 'push',
    path: '.github/workflows/ci.yml', status: 'completed', conclusion: 'success' };
  const jobs = ['Build & Test', 'iOS E2E (XCUITest)', 'Appcast & Cloudflare config contract',
    'Detect landing page changes', 'Landing page e2e (Playwright)']
    .map((name) => ({ name, status: 'completed', conclusion: 'success' }));
  const github = {
    rest: { git: { getRef: async () => ({ data: { object: { sha } } }) }, actions: {
      getWorkflowRun: async () => ({ data: run }),
      listWorkflowRuns: async (args) => {
        assert.equal(args.head_sha, sha);
        assert.equal(args.workflow_id, 'ci.yml');
        return { data: { workflow_runs: [run] } };
      },
      listJobsForWorkflowRun: () => {},
    } },
    paginate: async (_method, args) => {
      assert.equal(args.run_id, run.id);
      assert.equal(args.filter, 'latest');
      return jobs;
    },
  };
  return { run, jobs, args: { github, owner: 'owner', repo: 'repo', sha } };
}

test('automatic and manual deploy accept successful CI for the exact SHA', async () => {
  const { args } = fixture();
  assert.equal(await verifyLandingDeploy({ ...args, runId: 123 }), true);
  assert.equal(await verifyLandingDeploy(args), true);
});

test('other ref, workflow, event, failed or unfinished run cannot deploy', async () => {
  for (const change of [{ head_sha: 'b'.repeat(40) }, { head_branch: 'feature' },
    { path: '.github/workflows/unrelated.yml' }, { event: 'pull_request' },
    { conclusion: 'failure' }, { status: 'in_progress' }]) {
    const { run, args } = fixture();
    Object.assign(run, change);
    await assert.rejects(verifyLandingDeploy({ ...args, runId: 123 }), /No completed successful/);
  }
});

test('overall success cannot hide failed, skipped, cancelled or missing surface jobs', async () => {
  for (let index = 0; index < 5; index++) {
    for (const conclusion of ['failure', 'skipped', 'cancelled', null]) {
      const { jobs, args } = fixture();
      jobs[index].conclusion = conclusion;
      await assert.rejects(verifyLandingDeploy(args), /Deployment blocked/);
    }
    const { jobs, args } = fixture();
    jobs.splice(index, 1);
    await assert.rejects(verifyLandingDeploy(args), /Deployment blocked/);
  }
});

test('irrelevant auto run does not deploy; manual deploy still requires Playwright', async () => {
  const { jobs, args } = fixture();
  jobs[4].conclusion = 'skipped';
  assert.equal(await verifyLandingDeploy({ ...args, allowIrrelevantSkip: true }), false);
  await assert.rejects(verifyLandingDeploy(args), /Playwright did not succeed/);
  jobs[3].conclusion = 'failure';
  await assert.rejects(verifyLandingDeploy({ ...args, allowIrrelevantSkip: true }), /Detect landing page changes/);
});

test('missing CI and API errors fail closed', async () => {
  const { args } = fixture();
  args.github.rest.actions.listWorkflowRuns = async () => ({ data: { workflow_runs: [] } });
  await assert.rejects(verifyLandingDeploy(args), /No completed successful/);
  args.github.rest.actions.getWorkflowRun = async () => { throw new Error('API unavailable'); };
  await assert.rejects(verifyLandingDeploy({ ...args, runId: 123 }), /API unavailable/);
});

test('current main or an appcast-only descendant may deploy; other changes cannot', async () => {
  const { verifyCurrentLandingSource } = await import('../ci-verify-landing-deploy.mjs');
  const current = { object: { sha } };
  const comparison = { status: 'ahead', files: [{ filename: 'landing-page/appcast.xml', status: 'modified' }] };
  const github = { rest: {
    git: { getRef: async () => ({ data: current }) },
    repos: { compareCommits: async (args) => {
      assert.equal(args.base, sha);
      assert.equal(args.head, current.object.sha);
      return { data: comparison };
    } },
  } };
  const args = { github, owner: 'owner', repo: 'repo', sha };
  await verifyCurrentLandingSource(args);
  current.object.sha = 'b'.repeat(40);
  await verifyCurrentLandingSource(args);
  for (const change of [{ status: 'diverged' }, { files: [] }, { files: undefined },
    { files: [{ filename: 'landing-page/index.html', status: 'modified' }] },
    { files: [...comparison.files, { filename: 'Sources/PastaApp/main.swift', status: 'modified' }] },
    { files: [{ filename: 'landing-page/appcast.xml', status: 'removed' }] }]) {
    const saved = { ...comparison };
    Object.assign(comparison, change);
    await assert.rejects(verifyCurrentLandingSource(args), /superseded/);
    Object.assign(comparison, saved);
  }
});


test('release accepts exact-SHA completed gates while auto-release still pushes its tag', async () => {
  const { run, args } = fixture();
  await verifyReleasePublication(args);
  run.status = 'in_progress';
  run.conclusion = null;
  await verifyReleasePublication(args);
  await assert.rejects(verifyLandingDeploy(args), /No completed successful/);
});

test('release permits a push path skip only after every required surface and detector succeeded', async () => {
  const { run, jobs, args } = fixture();
  jobs[4].conclusion = 'skipped';
  await verifyReleasePublication(args);
  run.event = 'workflow_dispatch';
  await assert.rejects(verifyReleasePublication(args), /Playwright did not succeed/);
  run.event = 'push';
  jobs[3].conclusion = 'failure';
  await assert.rejects(verifyReleasePublication(args), /Detect landing page changes/);
});

test('manual tags cannot publish with missing, failed, cancelled, duplicated or unfinished gates', async () => {
  for (let index = 0; index < 5; index++) {
    for (const change of ['missing', 'duplicate', 'running', 'failure', 'cancelled', 'skipped']) {
      if (index === 4 && change === 'skipped') continue; // verified push path skip above
      const { run, jobs, args } = fixture();
      run.status = 'in_progress';
      run.conclusion = null;
      if (change === 'missing') jobs.splice(index, 1);
      else if (change === 'duplicate') jobs.push({ ...jobs[index] });
      else if (change === 'running') jobs[index].status = 'in_progress';
      else jobs[index].conclusion = change;
      await assert.rejects(verifyReleasePublication(args), /Deployment blocked/);
    }
  }
});

test('release rejects non-main, different-SHA, unrelated, queued or failed CI even with green jobs', async () => {
  for (const change of [{ head_sha: 'b'.repeat(40) }, { head_branch: 'feature' },
    { path: '.github/workflows/release.yml' }, { event: 'pull_request' },
    { conclusion: 'failure' }, { conclusion: 'cancelled' },
    { status: 'queued', conclusion: null }, { status: 'in_progress', conclusion: 'failure' }]) {
    const { run, args } = fixture();
    Object.assign(run, change);
    await assert.rejects(verifyReleasePublication(args), /No completed successful/);
  }
  const { args } = fixture();
  args.github.rest.actions.listWorkflowRuns = async () => ({ data: { workflow_runs: [] } });
  await assert.rejects(verifyReleasePublication(args), /No completed successful/);
});

test('release uses latest evidence and rejects main advancing to unverified source', async () => {
  const { run, args } = fixture();
  args.github.rest.actions.listWorkflowRuns = async () => ({ data: { workflow_runs: [
    { ...run, id: 456, conclusion: 'failure' }, run,
  ] } });
  await assert.rejects(verifyReleasePublication(args), /No completed successful/);
  args.github.rest.actions.listWorkflowRuns = async () => ({ data: { workflow_runs: [run] } });
  args.github.rest.git.getRef = async () => ({ data: { object: { sha: 'b'.repeat(40) } } });
  args.github.rest.repos = { compareCommits: async () => ({ data: {
    status: 'ahead', files: [{ filename: 'landing-page/index.html', status: 'modified' }],
  } }) };
  await assert.rejects(verifyReleasePublication(args), /superseded/);
});


test('historical manifest still requires every successful native surface', async () => {
  const {args,jobs,run}=fixture();
  args.github.rest.git.getRef=async()=>{throw Error('Historical source does not depend on moving main');};
  await verifyManifestPublication(args);
  for(const job of jobs) {
    job.conclusion='failure';
    await assert.rejects(verifyManifestPublication(args));
    job.conclusion='success';
  }
  run.status='in_progress';
  await assert.rejects(verifyManifestPublication(args));
});

test('workers stage only after native checks and immutable archive verification', async () => {
  const mac=await readFile(new URL('../../.github/workflows/release.yml',import.meta.url),'utf8');
  const ios=await readFile(new URL('../../.github/workflows/release-ios.yml',import.meta.url),'utf8');
  for(const worker of [mac,ios]) {
    assert.match(worker,/workflow_call:/);
    assert.match(worker,/ref: \$\{\{ inputs.manifest \}\}/);
    assert.match(worker,/await verifyManifestPublication/);
    assert.match(worker,/verify-release-train-archive.py/);
    assert.doesNotMatch(worker,/continue-on-error/);
  }
  assert.ok(mac.indexOf('Launch readiness smoke test') < mac.indexOf('Stage immutable candidate assets'));
  assert.ok(mac.indexOf('Verify Alpha download') < mac.indexOf('Publish Alpha prerelease only'));
  assert.match(ios,/needs: preflight/);
  assert.ok(ios.indexOf('Require every surface gate before TestFlight upload') < ios.indexOf('Export IPA and upload'));
});

test('Stable approval, website publication and failure recovery remain serial', async () => {
  const publish=await readFile(new URL('../../.github/workflows/publish-stable.yml',import.meta.url),'utf8');
  assert.match(publish,/group: landing-page-deploy/);
  assert.match(publish,/cancel-in-progress: false/);
  assert.match(publish,/approved_manifest_sha256/);
  assert.match(publish,/github.actor == github.repository_owner/);
  assert.match(publish,/always\(\) && \(failure\(\) \|\| cancelled\(\)\)/);
  assert.match(publish,/release-train.mjs withdraw/);
  assert.match(publish,/ci-verify-release.sh/);
});
