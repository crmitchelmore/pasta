// Shape checks for the Cloudflare Pages config files that ship with the site.
// Syntax reference: https://developers.cloudflare.com/pages/configuration/redirects/
// and https://developers.cloudflare.com/pages/configuration/headers/

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { LANDING_DIR } from '../support/appcast.mjs';

const REDIRECT_STATUSES = new Set(['200', '301', '302', '303', '307', '308']);
const HEADER_NAME = /^[A-Za-z0-9-]+$/;

function nonCommentLines(text) {
  return text
    .split(/\r?\n/)
    .map((line, i) => ({ line, number: i + 1 }))
    .filter(({ line }) => line.trim() !== '' && !line.trim().startsWith('#'));
}

test('_redirects is non-empty and every rule is "<from> <to> [status]"', () => {
  const text = readFileSync(resolve(LANDING_DIR, '_redirects'), 'utf8');
  const rules = nonCommentLines(text);
  assert.ok(rules.length >= 1, '_redirects has no rules');
  assert.ok(rules.length <= 2000, 'Cloudflare Pages allows at most 2000 static redirects');

  const seen = new Set();
  for (const { line, number } of rules) {
    const parts = line.trim().split(/\s+/);
    assert.ok(parts.length === 2 || parts.length === 3, `_redirects:${number}: expected 2 or 3 fields, got ${parts.length}: "${line}"`);
    const [from, to, status] = parts;

    assert.match(from, /^\//, `_redirects:${number}: source must start with "/": "${from}"`);
    assert.ok(!seen.has(from), `_redirects:${number}: duplicate source "${from}"`);
    seen.add(from);

    if (to.startsWith('/')) {
      assert.doesNotMatch(to, /\s/, `_redirects:${number}: target contains whitespace`);
    } else {
      const url = new URL(to); // throws on malformed URL
      assert.equal(url.protocol, 'https:', `_redirects:${number}: external targets must be https: "${to}"`);
    }

    if (status !== undefined) {
      assert.ok(REDIRECT_STATUSES.has(status), `_redirects:${number}: unsupported status "${status}"`);
    }
  }
});

test('_redirects keeps the /download, /github and /releases shortcuts pointing at GitHub', () => {
  const text = readFileSync(resolve(LANDING_DIR, '_redirects'), 'utf8');
  const byFrom = new Map(nonCommentLines(text).map(({ line }) => line.trim().split(/\s+/)).map(([from, to, status]) => [from, { to, status }]));

  assert.equal(byFrom.get('/download')?.to, 'https://github.com/crmitchelmore/pasta/releases/latest');
  assert.equal(byFrom.get('/download')?.status, '302');
  assert.equal(byFrom.get('/github')?.to, 'https://github.com/crmitchelmore/pasta');
  assert.equal(byFrom.get('/releases')?.to, 'https://github.com/crmitchelmore/pasta/releases');
});

test('_headers is non-empty and every block is a path followed by indented "Name: value" lines', () => {
  const text = readFileSync(resolve(LANDING_DIR, '_headers'), 'utf8');
  const lines = nonCommentLines(text);
  assert.ok(lines.length >= 2, '_headers has no rules');

  const blocks = [];
  let current = null;
  for (const { line, number } of lines) {
    const indented = /^\s/.test(line);
    if (!indented) {
      const path = line.trim();
      assert.match(path, /^(https?:\/\/[^/\s]+)?\/\S*$/, `_headers:${number}: expected a path (or absolute URL) starting a block, got "${path}"`);
      current = { path, headers: [], number };
      blocks.push(current);
      continue;
    }

    assert.ok(current, `_headers:${number}: header line before any path: "${line.trim()}"`);
    const separator = line.indexOf(':');
    assert.ok(separator > 0, `_headers:${number}: expected "Name: value", got "${line.trim()}"`);
    const name = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    assert.match(name, HEADER_NAME, `_headers:${number}: invalid header name "${name}"`);
    assert.ok(value.length > 0, `_headers:${number}: empty value for header "${name}"`);
    current.headers.push({ name, value });
  }

  for (const block of blocks) {
    assert.ok(block.headers.length >= 1, `_headers:${block.number}: block "${block.path}" declares no headers`);
    assert.ok(block.headers.length <= 100, `_headers:${block.number}: Cloudflare allows at most 100 headers per rule`);
  }
});

test('_headers hardens every page and keeps the appcast fresh for Sparkle', () => {
  const text = readFileSync(resolve(LANDING_DIR, '_headers'), 'utf8');
  const lines = nonCommentLines(text);

  const blocks = new Map();
  let current = null;
  for (const { line } of lines) {
    if (!/^\s/.test(line)) {
      current = new Map();
      blocks.set(line.trim(), current);
    } else {
      const [name, ...rest] = line.trim().split(':');
      current.set(name.trim().toLowerCase(), rest.join(':').trim());
    }
  }

  const global = blocks.get('/*');
  assert.ok(global, '_headers must have a "/*" block');
  assert.equal(global.get('x-content-type-options'), 'nosniff');
  assert.equal(global.get('x-frame-options'), 'DENY');
  assert.ok(global.has('referrer-policy'), 'Referrer-Policy on /*');

  const appcast = blocks.get('/appcast.xml');
  assert.ok(appcast, '_headers must have an "/appcast.xml" block so Sparkle clients pick up releases promptly');
  const cacheControl = appcast.get('cache-control') ?? '';
  const maxAge = /max-age=(\d+)/.exec(cacheControl);
  assert.ok(maxAge, `appcast Cache-Control must set max-age, got "${cacheControl}"`);
  assert.ok(Number(maxAge[1]) <= 86_400, `appcast max-age ${maxAge[1]}s is longer than a day; updates would be delayed`);
  assert.doesNotMatch(cacheControl, /immutable/, 'appcast must never be immutable');
});
