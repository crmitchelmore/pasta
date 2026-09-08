// Give production failures a durable owner instead of relying on the scheduled
// workflow actor's personal email settings. Only manage this bot's own issues.
export const incidentMarker = '<!-- pasta-production-monitor -->';

export async function reportMonitorResult({ github, owner, repo, runId, status }) {
  if (status === 'cancelled') return;
  if (!['success', 'failure'].includes(status) || !/^\d+$/.test(String(runId))) {
    throw new Error('Missing monitor outcome or run identifier');
  }
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    owner, repo, state: 'open', creator: 'github-actions[bot]', per_page: 100,
  });
  const incidents = issues.filter(issue => !issue.pull_request
    && issue.user?.login === 'github-actions[bot]'
    && issue.body?.startsWith(incidentMarker));
  const runURL = `https://github.com/${owner}/${repo}/actions/runs/${runId}`;
  if (status === 'success') {
    for (const issue of incidents) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number,
        body: `${issue.body}\n\nRecovered: [production probe passed](${runURL}).`,
        state: 'closed', state_reason: 'completed' });
    }
    return;
  }
  const body = `${incidentMarker}\nThe production monitor failed. Owner: @${owner}.\n\n`
    + `[Inspect the failing workflow](${runURL}) for the site, download, appcast or published-release error.\n\n`
    + `Follow [the recovery procedure](https://github.com/${owner}/${repo}/blob/main/Docs/operations-recovery.md), then rerun Production monitor. A successful probe automatically closes this incident.\n\n`
    + 'Do not rewrite the feed to match a failed or unpublished tag.';
  if (incidents.length) {
    await github.rest.issues.update({ owner, repo, issue_number: incidents[0].number,
      body, assignees: [owner] });
  } else {
    await github.rest.issues.create({ owner, repo,
      title: 'Production monitor: pasta-app.com needs attention', body, assignees: [owner] });
  }
}
