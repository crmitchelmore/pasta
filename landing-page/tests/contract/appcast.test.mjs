// Contract test for the Sparkle appcast shipped from landing-page/appcast.xml.
//
// Runs offline in plain Node on every push/PR (see .github/workflows/ci.yml,
// job "appcast-contract"). The macOS app reads https://pasta-app.com/appcast.xml
// via SUFeedURL, so a malformed feed here silently breaks auto-updates.
//
// Note on freshness: .github/workflows/release.yml regenerates the appcast,
// deploys it to Cloudflare Pages and then commits it back to main
// (scripts/ci-commit-appcast.sh), so the copy in git is expected to name the
// newest PUBLISHED release. CI resolves that with `gh release list` into
// APPCAST_LATEST_PUBLISHED and runs with APPCAST_REQUIRE_LATEST=1, which turns
// a lag into a failure: it means the commit-back did not land (check the
// release run for a ::warning:: and a release/appcast-v* branch). A tag whose
// release failed or was drafted is NOT a reference (issue #113), and without
// published-release information the lag is only reported.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  DMG_URL,
  SEMVER,
  assessFreshness,
  compareSemver,
  gitTagExists,
  latestGitTagVersion,
  latestPublishedReleaseVersion,
  parseAppcast,
  readRepoAppcast,
} from '../support/appcast.mjs';

const SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const xml = readRepoAppcast();

test('appcast.xml is well-formed XML with the Sparkle namespace', () => {
  const appcast = parseAppcast(xml);
  assert.equal(appcast.rssVersion, '2.0', 'rss version');
  assert.equal(appcast.sparkleNamespace, SPARKLE_NS, 'xmlns:sparkle');
  assert.ok(appcast.channel.title, 'channel <title>');
  assert.ok(appcast.channel.link, 'channel <link>');
  assert.match(String(appcast.channel.link), /^https:\/\//, 'channel link is https');
});

test('appcast.xml has at least one item', () => {
  const { items } = parseAppcast(xml);
  assert.ok(items.length >= 1, 'expected >= 1 <item>');
});

test('every item has version fields, a signed DMG enclosure and a length', () => {
  const { items } = parseAppcast(xml);
  for (const item of items) {
    const where = `item[${item.index}] (${item.title ?? 'untitled'})`;

    assert.ok(item.title, `${where}: <title>`);
    assert.match(item.shortVersion ?? '', SEMVER, `${where}: sparkle:shortVersionString must be x.y.z`);
    assert.match(item.buildVersion ?? '', /^\d+$/, `${where}: sparkle:version must be an integer build number`);
    assert.ok(item.pubDate, `${where}: <pubDate>`);
    assert.ok(!Number.isNaN(new Date(item.pubDate).getTime()), `${where}: pubDate must parse: ${item.pubDate}`);
    assert.match(item.minimumSystemVersion ?? '', /^\d+(\.\d+)*$/, `${where}: sparkle:minimumSystemVersion`);

    const { url, length, type, edSignature } = item.enclosure;
    const match = DMG_URL.exec(url ?? '');
    assert.ok(match, `${where}: enclosure url must be a GitHub release DMG, got ${url}`);
    const [, tagVersion, fileVersion] = match;
    assert.equal(tagVersion, item.shortVersion, `${where}: enclosure tag version must match shortVersionString`);
    assert.equal(fileVersion, item.shortVersion, `${where}: DMG file name version must match shortVersionString`);
    assert.equal(item.title, `Version ${item.shortVersion}`, `${where}: title matches version`);

    assert.match(length ?? '', /^[1-9]\d*$/, `${where}: enclosure length must be a positive integer`);
    assert.ok(Number(length) > 1_000_000, `${where}: enclosure length ${length} is implausibly small for a DMG`);
    assert.equal(type, 'application/octet-stream', `${where}: enclosure type`);

    assert.ok(edSignature, `${where}: sparkle:edSignature is required`);
    // Ed25519 signature: 64 bytes -> 88 base64 characters ending in "==".
    assert.match(edSignature, /^[A-Za-z0-9+/]{86}==$/, `${where}: sparkle:edSignature must be a base64 Ed25519 signature`);
    assert.equal(Buffer.from(edSignature, 'base64').length, 64, `${where}: sparkle:edSignature must decode to 64 bytes`);
  }
});

test('items are in descending version order with unique versions', () => {
  const { items } = parseAppcast(xml);
  const shortVersions = items.map((i) => i.shortVersion);
  const buildVersions = items.map((i) => Number(i.buildVersion));

  assert.equal(new Set(shortVersions).size, shortVersions.length, 'duplicate shortVersionString');
  assert.equal(new Set(buildVersions).size, buildVersions.length, 'duplicate sparkle:version');

  for (let i = 1; i < items.length; i += 1) {
    assert.ok(
      compareSemver(shortVersions[i - 1], shortVersions[i]) > 0,
      `item[${i - 1}] ${shortVersions[i - 1]} must be newer than item[${i}] ${shortVersions[i]}`,
    );
    assert.ok(
      buildVersions[i - 1] > buildVersions[i],
      `item[${i - 1}] build ${buildVersions[i - 1]} must be greater than item[${i}] build ${buildVersions[i]}`,
    );
  }
});

test('top item points at a real release tag and tracks the newest PUBLISHED release', (t) => {
  const { items } = parseAppcast(xml);
  const top = items[0].shortVersion;
  const latestTag = latestGitTagVersion();
  const latestPublished = latestPublishedReleaseVersion();

  if (!latestTag && !latestPublished) {
    t.diagnostic('no v* tags in this checkout (shallow clone?) and no APPCAST_LATEST_PUBLISHED - skipping freshness');
    t.skip('no release reference available');
    return;
  }

  if (latestTag) {
    assert.ok(gitTagExists(top), `appcast top version ${top} has no matching git tag v${top}`);
  }

  // A tag is created before its release is built and published, so the
  // reference for freshness is the newest PUBLISHED release (CI passes it in
  // as APPCAST_LATEST_PUBLISHED); see assessFreshness and issue #113.
  const verdict = assessFreshness({
    top,
    latestTag,
    latestPublished,
    requireLatest: process.env.APPCAST_REQUIRE_LATEST === '1',
  });
  if (verdict.level === 'fail') {
    assert.fail(verdict.message);
  }
  if (verdict.level === 'warn') {
    t.diagnostic(`WARNING: ${verdict.message}`);
  } else {
    t.diagnostic(verdict.message);
  }
});
