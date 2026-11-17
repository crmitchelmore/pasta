import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fetchLatestPublishedReleaseVersion } from '../support/github-release.mjs';

test('release lookup authenticates only to GitHub and supports tokenless local probes', async (t) => {
  const original = { GH_TOKEN: process.env.GH_TOKEN, GITHUB_TOKEN: process.env.GITHUB_TOKEN };
  t.after(() => {
    for (const [name, value] of Object.entries(original)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  for (const [ghToken, githubToken, expected] of [
    ['gh-test-token', 'github-test-token', 'Bearer gh-test-token'],
    ['', 'github-test-token', 'Bearer github-test-token'],
    ['', '', undefined],
  ]) {
    process.env.GH_TOKEN = ghToken;
    process.env.GITHUB_TOKEN = githubToken;
    const request = t.mock.method(globalThis, 'fetch', async (url, options) => {
      assert.equal(url, 'https://api.github.com/repos/crmitchelmore/pasta/releases/latest');
      assert.equal(options.headers.authorization, expected);
      assert.equal(options.redirect, 'error');
      return Response.json({ tag_name: 'v1.10.0' });
    });
    assert.equal(await fetchLatestPublishedReleaseVersion(), '1.10.0');
    assert.equal(request.mock.callCount(), 1);
    request.mock.restore();
  }
});

test('release lookup fails closed for unavailable or malformed published-release evidence', async (t) => {
  for (const status of [401, 403, 404, 500]) {
    const request = t.mock.method(globalThis, 'fetch', async () => new Response('', { status }));
    await assert.rejects(fetchLatestPublishedReleaseVersion(), /GitHub releases\/latest unavailable/);
    request.mock.restore();
  }
  for (const body of [{}, { tag_name: 'v1.10.1-alpha.1' }, { tag_name: 'not-a-version' }]) {
    const request = t.mock.method(globalThis, 'fetch', async () => Response.json(body));
    await assert.rejects(fetchLatestPublishedReleaseVersion(), /Invalid published release version/);
    request.mock.restore();
  }
});
