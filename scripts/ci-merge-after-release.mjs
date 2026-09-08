#!/usr/bin/env node
// Keep the strict superseded-source publication policy. A new merge waits for
// both release lanes and landing deployment, including jobs queued for runners.
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export function assertReleaseLanesIdle(runs) {
  const active = runs.filter(run => run.status !== 'completed');
  if (active.length) throw new Error(`Merge blocked by unfinished publication: ${active.map(run => `${run.name ?? run.workflowName} (${run.html_url ?? run.url})`).join(', ')}`);
}

export async function verifyMergeWindow({ api, repo, expectedMain }) {
  const current = await api(`repos/${repo}/git/ref/heads/main`);
  if (current.object.sha !== expectedMain) throw new Error('main advanced; refresh the PR and recheck publication');
  for (const workflow of ['ci.yml', 'release.yml', 'release-ios.yml', 'deploy-landing-page.yml']) {
    // Query statuses independently, so a busy repository cannot hide an old
    // queued release behind the most recent 100 completed runs.
    for (const status of ['queued', 'in_progress', 'waiting', 'pending', 'requested']) {
      const response = await api(`repos/${repo}/actions/workflows/${workflow}/runs?status=${status}&per_page=100`);
      if (!Array.isArray(response.workflow_runs)) throw new Error('Missing workflow evidence');
      const runs = workflow === 'ci.yml'
        ? response.workflow_runs.filter(run => run.head_branch === 'main' && run.event === 'push')
        : response.workflow_runs;
      assertReleaseLanesIdle(runs);
    }
  }
  const after = await api(`repos/${repo}/git/ref/heads/main`);
  if (after.object.sha !== expectedMain) throw new Error('main advanced while checking publication');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [pr, ...flags] = process.argv.slice(2);
  if (!/^\d+$/.test(pr ?? '') || flags.some(flag => flag !== '--check')) {
    throw new Error('Usage: scripts/ci-merge-after-release.mjs <PR number> [--check]');
  }
  const gh = args => execFileSync('gh', args, { encoding: 'utf8' }).trim();
  const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/pasta';
  const api = async path => JSON.parse(gh(['api', path]));
  const pull = JSON.parse(gh(['pr', 'view', pr, '--repo', repo, '--json', 'headRefOid,baseRefName,isDraft,reviewDecision']));
  if (pull.baseRefName !== 'main' || pull.isDraft || pull.reviewDecision === 'CHANGES_REQUESTED') {
    throw new Error('PR must target main, be ready, and have no requested changes');
  }
  // GitHub remains authoritative about each required check. Never use --admin.
  gh(['pr', 'checks', pr, '--repo', repo, '--required']);
  const main = await api(`repos/${repo}/git/ref/heads/main`);
  await verifyMergeWindow({ api, repo, expectedMain: main.object.sha });
  if (flags.includes('--check')) console.log(`Publication lanes idle; PR #${pr} required checks passed.`);
  else {
    gh(['pr', 'merge', pr, '--repo', repo, '--squash', '--match-head-commit', pull.headRefOid]);
    console.log(`Merged PR #${pr}; wait for both releases and live verification before the next merge.`);
  }
}
