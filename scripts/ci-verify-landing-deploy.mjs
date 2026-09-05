// Shared read-only policy for both publishers. GitHub's overall workflow
// conclusion is insufficient: a required surface could have been skipped.
async function verifySurfaceCI({ github, owner, repo, sha, runId,
  allowIrrelevantSkip = false, allowRunningCI = false }) {
  let run;
  if (runId) {
    ({ data: run } = await github.rest.actions.getWorkflowRun({ owner, repo, run_id: runId }));
  } else {
    const { data } = await github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: 'ci.yml', head_sha: sha,
      branch: 'main', per_page: 20,
    });
    // Require the newest attempt/run for this SHA; an older green run must
    // not override a currently failing or incomplete run.
    run = data.workflow_runs[0];
  }
  const acceptedState = run && ((run.status === 'completed' && run.conclusion === 'success')
    || (allowRunningCI && run.status === 'in_progress' && run.conclusion === null));
  if (!run || run.head_sha !== sha || run.head_branch !== 'main' || !['push', 'workflow_dispatch'].includes(run.event)
      || run.path !== '.github/workflows/ci.yml'
      || !acceptedState) {
    throw new Error(`No completed successful main CI run${allowRunningCI ? ' (or active run with completed gates)' : ''} verifies deployment SHA ${sha}`);
  }
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    owner, repo, run_id: run.id, filter: 'latest', per_page: 100,
  });
  const required = ['Build & Test', 'iOS E2E (XCUITest)',
    'Appcast & Cloudflare config contract', 'Detect landing page changes'];
  for (const name of required) {
    const matches = jobs.filter((job) => job.name === name);
    if (matches.length !== 1 || matches[0].status !== 'completed' || matches[0].conclusion !== 'success') {
      throw new Error(`Deployment blocked: ${name} did not succeed for ${sha}`);
    }
  }
  const browser = jobs.filter((job) => job.name === 'Landing page e2e (Playwright)');
  if (browser.length !== 1 || browser[0].status !== 'completed') {
    throw new Error(`Deployment blocked: missing or incomplete Playwright evidence for ${sha}`);
  }
  // ci.yml only skips this job on push when successful path detection says
  // there are no relevant changes. Manual CI always runs the browser suite.
  if (allowIrrelevantSkip && run.event === 'push' && browser[0].conclusion === 'skipped') return false;
  if (browser[0].conclusion !== 'success') {
    throw new Error(`Deployment blocked: Playwright did not succeed for ${sha}; run CI with the browser suite before deploying`);
  }
  return true;
}

export async function verifyLandingDeploy(options) {
  return verifySurfaceCI({ ...options, allowRunningCI: false });
}

// A tag may be created manually, so auto-release's needs: is not evidence.
// Its CI run can still be active after pushing the tag; every required job
// must already be completed successfully, regardless of overall run state.
export async function verifyReleasePublication(options) {
  await verifySurfaceCI({ ...options, allowRunningCI: true, allowIrrelevantSkip: true });
  await verifyCurrentLandingSource(options);
}

// Release commits appcast.xml back with [skip ci]. Permit that descendant
// without rerunning page tests, but never publish over different page/app code.
export async function verifyCurrentLandingSource({ github, owner, repo, sha }) {
  const { data: current } = await github.rest.git.getRef({ owner, repo, ref: 'heads/main' });
  if (current.object.sha === sha) return;
  const { data: comparison } = await github.rest.repos.compareCommits({
    owner, repo, base: sha, head: current.object.sha,
  });
  if (comparison.status !== 'ahead' || !Array.isArray(comparison.files)
      || comparison.files.length !== 1
      || comparison.files[0].filename !== 'landing-page/appcast.xml'
      || comparison.files[0].status !== 'modified') {
    throw new Error(`Deployment SHA ${sha} was superseded by unverified changes on main (${current.object.sha})`);
  }
}
