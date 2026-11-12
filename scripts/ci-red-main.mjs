// Responds to a finished CI run on main. The full native suites (bundle launch
// smoke, iOS XCUITest) run after merge, so a regression can now land on main.
// Alpha never allocates from a red run, and ci-merge-after-release.mjs blocks
// further merges until main is green again; this gives the breakage a durable
// owner: one incident issue naming the failed jobs and the suspect PRs since
// the last green run, plus a comment on each suspect PR. A later green run
// closes the incident. Nothing here reruns, reverts or pushes: a revert is an
// ordinary PR through the same gates, and failures are never retried into a pass.
export const incidentMarker = '<!-- pasta-red-main -->';
const verdicts = new Set(['success', 'failure', 'timed_out', 'startup_failure', 'action_required']);

// The newest completed verdict decides; an older run finishing late is stale.
export function isStale(run, completedRuns) {
  return completedRuns.some(other => other.id !== run.id
    && verdicts.has(other.conclusion)
    && Date.parse(other.created_at) > Date.parse(run.created_at));
}

export function lastGreenBefore(run, completedRuns) {
  return completedRuns
    .filter(other => other.conclusion === 'success' && Date.parse(other.created_at) < Date.parse(run.created_at))
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
}

export function failedJobs(jobs) {
  return jobs.filter(job => ['failure', 'timed_out', 'cancelled'].includes(job.conclusion)).map(job => job.name);
}

// Squash merges end their subject with "(#123)".
export function suspectPulls(commits) {
  const numbers = commits.map(commit => commit.commit?.message?.split('\n')[0].match(/\(#(\d+)\)\s*$/)?.[1])
    .filter(Boolean).map(Number);
  return [...new Set(numbers)];
}

export function incidentBody({ owner, repo, run, jobs, commits, pulls, base }) {
  const short = sha => sha.slice(0, 7);
  const range = base
    ? `[${short(base)}...${short(run.head_sha)}](https://github.com/${owner}/${repo}/compare/${base}...${run.head_sha})`
    : 'no earlier green run found';
  return [
    incidentMarker,
    `CI is red on main at ${short(run.head_sha)}. Owner: @${owner}.`,
    '',
    `- Run: ${run.html_url}`,
    `- Failed jobs: ${jobs.length ? jobs.join(', ') : 'see the run'}`,
    `- Since the last green run: ${range}`,
    `- Suspect PRs: ${pulls.length ? pulls.map(number => `#${number}`).join(', ') : 'none identified'}`,
    ...commits.slice(0, 20).map(commit => `  - ${short(commit.sha)} ${commit.commit.message.split('\n')[0]}`),
    '',
    'Alpha does not publish from this run, and `scripts/ci-merge-after-release.mjs` refuses other merges until main is green.',
    'Fix forward (`scripts/ci-merge-after-release.mjs <PR> --fix-forward`) or revert the suspect through a normal PR. Do not rerun a failed suite into a pass.',
    'The next green CI run on main closes this issue.',
  ].join('\n');
}

export async function reportMainCI({ github, owner, repo, run }) {
  if (!run || !/^\d+$/.test(String(run.id)) || !/^[0-9a-f]{40}$/.test(run.head_sha ?? '')) {
    throw new Error('Missing CI run evidence');
  }
  if (run.event !== 'push' || run.head_branch !== 'main' || !verdicts.has(run.conclusion)) return 'ignored';
  const { data: completed } = await github.rest.actions.listWorkflowRuns({
    owner, repo, workflow_id: run.workflow_id, branch: 'main', event: 'push', status: 'completed', per_page: 50,
  });
  if (isStale(run, completed.workflow_runs)) return 'stale';

  const issues = await github.paginate(github.rest.issues.listForRepo, {
    owner, repo, state: 'open', creator: 'github-actions[bot]', per_page: 100,
  });
  const incidents = issues.filter(issue => !issue.pull_request
    && issue.user?.login === 'github-actions[bot]' && issue.body?.startsWith(incidentMarker));

  if (run.conclusion === 'success') {
    for (const issue of incidents) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number,
        body: `${issue.body}\n\nRecovered: [main is green at ${run.head_sha.slice(0, 7)}](${run.html_url}).`,
        state: 'closed', state_reason: 'completed' });
    }
    return incidents.length ? 'closed' : 'green';
  }

  const jobs = failedJobs(await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    owner, repo, run_id: run.id, per_page: 100,
  }));
  const base = lastGreenBefore(run, completed.workflow_runs)?.head_sha;
  const commits = base
    ? (await github.rest.repos.compareCommitsWithBasehead({ owner, repo, basehead: `${base}...${run.head_sha}` })).data.commits.reverse()
    : [];
  const pulls = suspectPulls(commits);
  const body = incidentBody({ owner, repo, run, jobs, commits, pulls, base });
  let issueNumber;
  if (incidents.length) {
    issueNumber = incidents[0].number;
    await github.rest.issues.update({ owner, repo, issue_number: issueNumber, body, assignees: [owner] });
  } else {
    issueNumber = (await github.rest.issues.create({ owner, repo,
      title: 'CI failing on main', body, assignees: [owner] })).data.number;
  }
  const commentMarker = `<!-- pasta-red-main:${run.head_sha} -->`;
  for (const number of pulls) {
    const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: number, per_page: 100 });
    if (comments.some(comment => comment.body?.includes(commentMarker))) continue;
    await github.rest.issues.createComment({ owner, repo, issue_number: number,
      body: `${commentMarker}\nPost-merge CI is red on main at ${run.head_sha.slice(0, 7)} (${jobs.join(', ') || 'see the run'}), and this PR is in the range since the last green run. See #${issueNumber} and ${run.html_url}.` });
  }
  return 'red';
}
