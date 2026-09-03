// Shared helpers for the appcast contract test and the live probe.
// Plain Node (no browser) so they can run in seconds on every push.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { XMLParser, XMLValidator } from 'fast-xml-parser';

export const LANDING_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const REPO_ROOT = resolve(LANDING_DIR, '..');
export const APPCAST_PATH = resolve(LANDING_DIR, 'appcast.xml');

export const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;
export const DMG_URL =
  /^https:\/\/github\.com\/crmitchelmore\/pasta\/releases\/download\/v(\d+\.\d+\.\d+)\/Pasta-(\d+\.\d+\.\d+)\.dmg$/;

export function readRepoAppcast() {
  return readFileSync(APPCAST_PATH, 'utf8');
}

/** Numeric semver comparison: negative if a < b, 0 if equal, positive if a > b. */
export function compareSemver(a, b) {
  const pa = a.match(SEMVER);
  const pb = b.match(SEMVER);
  if (!pa || !pb) throw new Error(`compareSemver expects x.y.z, got "${a}" and "${b}"`);
  for (let i = 1; i <= 3; i += 1) {
    const diff = Number(pa[i]) - Number(pb[i]);
    if (diff !== 0) return diff;
  }
  return 0;
}

/**
 * Parse a Sparkle appcast into a normalised structure.
 * Throws if the document is not well-formed XML.
 */
export function parseAppcast(xml) {
  const validity = XMLValidator.validate(xml);
  if (validity !== true) {
    const { msg, line, col } = validity.err;
    throw new Error(`appcast.xml is not well-formed XML: ${msg} (line ${line}, col ${col})`);
  }

  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: '@_',
    removeNSPrefix: false,
    // Always treat <item> as a list so a single-item feed parses the same as many.
    isArray: (name, jpath) => jpath === 'rss.channel.item',
    // Keep version strings as strings ("60" must not become 60, "1.10" must not become 1.1).
    parseTagValue: false,
    parseAttributeValue: false,
  });
  const doc = parser.parse(xml);
  const rss = doc.rss;
  if (!rss) throw new Error('appcast.xml has no <rss> root element');

  const channel = rss.channel ?? {};
  const items = (channel.item ?? []).map((item, index) => {
    const enclosure = item.enclosure ?? {};
    const text = (value) => (value === undefined || value === null ? undefined : String(value).trim());
    return {
      index,
      title: text(item.title),
      shortVersion: text(item['sparkle:shortVersionString']),
      buildVersion: text(item['sparkle:version']),
      pubDate: text(item.pubDate),
      minimumSystemVersion: text(item['sparkle:minimumSystemVersion']),
      hasDescription: item.description !== undefined,
      enclosure: {
        url: text(enclosure['@_url']),
        length: text(enclosure['@_length']),
        type: text(enclosure['@_type']),
        edSignature: text(enclosure['@_sparkle:edSignature']),
      },
    };
  });

  return {
    sparkleNamespace: rss['@_xmlns:sparkle'],
    rssVersion: rss['@_version'],
    channel: {
      title: channel.title,
      link: channel.link,
      description: channel.description,
      language: channel.language,
    },
    items,
  };
}

/**
 * Newest `v*` tag known to the local git checkout, as "x.y.z" (no "v"), or
 * null when the checkout has no version tags (e.g. a shallow clone).
 */
export function latestGitTagVersion() {
  try {
    const out = execFileSync('git', ['tag', '-l', 'v*', '--sort=-v:refname'], {
      cwd: REPO_ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const first = out.split('\n').map((s) => s.trim()).find((tag) => /^v\d+\.\d+\.\d+$/.test(tag));
    return first ? first.slice(1) : null;
  } catch {
    return null;
  }
}

/** True when the local checkout has a tag `v<version>`. */
export function gitTagExists(version) {
  try {
    const out = execFileSync('git', ['tag', '-l', `v${version}`], {
      cwd: REPO_ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return out.trim() === `v${version}`;
  } catch {
    return false;
  }
}
