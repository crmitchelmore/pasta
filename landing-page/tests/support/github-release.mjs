import assert from 'node:assert/strict';

export async function fetchLatestPublishedReleaseVersion() {
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  const response = await fetch('https://api.github.com/repos/crmitchelmore/pasta/releases/latest', {
    headers: {
      'user-agent': 'pasta-landing-live-probe/1 (+https://github.com/crmitchelmore/pasta)',
      accept: 'application/vnd.github+json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    signal: AbortSignal.timeout(20_000),
    redirect: 'error',
  });
  assert.equal(response.status, 200, 'Cannot verify published release: GitHub releases/latest unavailable');
  const body = await response.json();
  const published = String(body.tag_name ?? '').replace(/^v/, '');
  assert.match(published, /^\d+\.\d+\.\d+$/, 'Invalid published release version');
  return published;
}
