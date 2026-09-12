import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const workflow = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../.github/workflows/release-ios.yml'), 'utf8');
const job = name => {
  const start = workflow.indexOf(`\n  ${name}:\n`);
  assert.notEqual(start, -1, `${name} job missing`);
  const rest = workflow.slice(start + 1);
  const next = rest.slice(1).search(/\n  [a-z-]+:\n/);
  return next >= 0 ? rest.slice(0, next + 1) : rest;
};

test('preflight tests the pristine tagged source; only testflight stamps the manifest', () => {
  const preflight = job('preflight');
  const testflight = job('testflight');
  // configure rewrites the bundled iOS release-notes catalogue with the train's
  // own history, which the What's New UI test does not tolerate.
  assert.doesNotMatch(preflight, /release-train\.mjs configure/);
  assert.doesNotMatch(preflight, /configure-release-train\.py/);
  assert.match(preflight, /ci-ios-e2e\.sh test/);
  assert.match(testflight, /release-train\.mjs configure --tag "\$MANIFEST" --surface ios/);
  assert.match(testflight, /configure-release-train\.py/);
});
