// ADVISORY live probe of the deployed site. Requires network access.
//
// Not part of the offline suite: it runs only on pushes to main and manual
// dispatches, with `continue-on-error: true` in CI, because a CDN hiccup or a
// GitHub outage must never block a merge. Treat a red run as a prompt to look,
// not as a broken build.
//
// Checks:
//   - https://pasta-app.com/ and /appcast.xml respond 200 with the expected
//     security/cache headers from _headers.
//   - /download redirects (302) to the GitHub "latest release" page.
//   - The live appcast parses, its top enclosure DMG URL answers 200/302, and
//     its top version equals the newest v* tag in this checkout - i.e. the
//     release workflow actually regenerated and deployed the feed.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DMG_URL, compareSemver, latestGitTagVersion, parseAppcast } from '../support/appcast.mjs';

const ORIGIN = process.env.LANDING_LIVE_ORIGIN ?? 'https://pasta-app.com';
const TIMEOUT_MS = 20_000;
const UA = 'pasta-landing-live-probe/1 (+https://github.com/crmitchelmore/pasta)';

async function probe(url, { method = 'HEAD', redirect = 'manual' } = {}) {
  const response = await fetch(url, {
    method,
    redirect,
    headers: { 'user-agent': UA, 'cache-control': 'no-cache' },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  return response;
}

test(`live: ${ORIGIN}/ responds 200 with security headers`, async () => {
  const response = await probe(`${ORIGIN}/`);
  assert.equal(response.status, 200, `HEAD ${ORIGIN}/`);
  assert.match(response.headers.get('content-type') ?? '', /text\/html/);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff', '_headers not applied on /');
  assert.equal(response.headers.get('x-frame-options'), 'DENY', '_headers not applied on /');
});

test('live: /download redirects to the latest GitHub release', async () => {
  const response = await probe(`${ORIGIN}/download`);
  assert.equal(response.status, 302, 'expected the _redirects 302');
  assert.equal(response.headers.get('location'), 'https://github.com/crmitchelmore/pasta/releases/latest');
});

test('live: appcast.xml is served, parses, and its top DMG is downloadable', async (t) => {
  const response = await probe(`${ORIGIN}/appcast.xml`, { method: 'GET' });
  assert.equal(response.status, 200, `GET ${ORIGIN}/appcast.xml`);
  assert.match(response.headers.get('cache-control') ?? '', /max-age=\d+/, 'appcast Cache-Control from _headers');

  const appcast = parseAppcast(await response.text());
  assert.ok(appcast.items.length >= 1, 'live appcast has no items');
  const top = appcast.items[0];
  t.diagnostic(`live appcast top item: ${top.shortVersion} (build ${top.buildVersion})`);

  assert.match(top.enclosure.url ?? '', DMG_URL, 'live top enclosure URL');
  assert.ok(top.enclosure.edSignature, 'live top item is unsigned');

  // GitHub answers release asset URLs with a 302 to objects.githubusercontent.com.
  const dmg = await probe(top.enclosure.url);
  assert.ok([200, 302].includes(dmg.status), `HEAD ${top.enclosure.url} returned ${dmg.status}`);
});

test('live: appcast top version equals the newest v* git tag', async (t) => {
  const latest = latestGitTagVersion();
  if (!latest) {
    t.skip('no v* tags in this checkout (shallow clone?)');
    return;
  }

  const response = await probe(`${ORIGIN}/appcast.xml`, { method: 'GET' });
  assert.equal(response.status, 200);
  const { items } = parseAppcast(await response.text());
  const live = items[0].shortVersion;

  assert.equal(
    compareSemver(live, latest),
    0,
    `live appcast serves ${live} but the newest tag is v${latest}. ` +
      (compareSemver(live, latest) < 0
        ? 'The release workflow did not regenerate/deploy the appcast, or a landing-page deploy overwrote it with the stale copy in git.'
        : 'The live feed is ahead of the tags in this checkout; fetch tags or check for a stray deploy.'),
  );
});
