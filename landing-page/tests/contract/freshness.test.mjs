// Scenario tests for assessFreshness (issue #113): the appcast in git must
// track the newest PUBLISHED release, and a tag whose release failed before
// publication must never deadlock CI.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessFreshness } from '../support/appcast.mjs';

const cases = [
  {
    name: 'healthy: feed, newest tag and newest published release agree',
    input: { top: '1.5.14', latestTag: '1.5.14', latestPublished: '1.5.14', requireLatest: true },
    level: 'ok',
  },
  {
    name: 'tag created but its release failed before publication: feed stays on the published one (no deadlock)',
    input: { top: '1.5.14', latestTag: '1.5.15', latestPublished: '1.5.14', requireLatest: true },
    level: 'ok',
  },
  {
    name: 'release drafted/pulled after the feed advertised it: feed is ahead of what is published',
    input: { top: '1.5.15', latestTag: '1.5.15', latestPublished: '1.5.14', requireLatest: true },
    level: 'fail',
    messageIncludes: 'newest PUBLISHED release is 1.5.14',
  },
  {
    name: 'newer healthy release superseded the feed: strict mode fails',
    input: { top: '1.5.14', latestTag: '1.5.15', latestPublished: '1.5.15', requireLatest: true },
    level: 'fail',
    messageIncludes: 'ci-commit-appcast.sh',
  },
  {
    name: 'newer healthy release superseded the feed: non-strict only warns',
    input: { top: '1.5.14', latestTag: '1.5.15', latestPublished: '1.5.15', requireLatest: false },
    level: 'warn',
  },
  {
    name: 'feed ahead of every tag: the release does not exist',
    input: { top: '1.6.0', latestTag: '1.5.15', latestPublished: '1.5.15', requireLatest: true },
    level: 'fail',
    messageIncludes: 'AHEAD of the newest tag',
  },
  {
    name: 'no published-release information: a lag behind the newest tag is only a warning, even in strict mode',
    input: { top: '1.5.14', latestTag: '1.5.15', latestPublished: null, requireLatest: true },
    level: 'warn',
    messageIncludes: 'APPCAST_LATEST_PUBLISHED',
  },
  {
    name: 'no published-release information, feed equals newest tag',
    input: { top: '1.5.15', latestTag: '1.5.15', latestPublished: null, requireLatest: true },
    level: 'ok',
  },
  {
    name: 'published release known but tags unavailable (shallow clone): published wins',
    input: { top: '1.5.14', latestTag: null, latestPublished: '1.5.14', requireLatest: true },
    level: 'ok',
  },
];

for (const c of cases) {
  test(`freshness: ${c.name}`, () => {
    const verdict = assessFreshness(c.input);
    assert.equal(verdict.level, c.level, verdict.message);
    if (c.messageIncludes) {
      assert.ok(verdict.message.includes(c.messageIncludes), `message should mention "${c.messageIncludes}": ${verdict.message}`);
    }
  });
}

test('freshness: an older feed must never be accepted over a newer published release in strict mode', () => {
  for (const older of ['1.5.0', '1.5.13', '1.4.99']) {
    const verdict = assessFreshness({ top: older, latestTag: '1.5.14', latestPublished: '1.5.14', requireLatest: true });
    assert.equal(verdict.level, 'fail', `${older} vs published 1.5.14 should fail: ${verdict.message}`);
  }
});
