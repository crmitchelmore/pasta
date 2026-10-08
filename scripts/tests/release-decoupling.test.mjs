import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const read = name => readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../.github/workflows', name), 'utf8');
const job = (workflow, name) => {
  const start = workflow.indexOf(`\n  ${name}:\n`);
  assert.notEqual(start, -1, `${name} job missing`);
  const rest = workflow.slice(start + 1);
  const next = rest.slice(1).search(/\n  [a-z-]+:\n/);
  return next >= 0 ? rest.slice(0, next + 1) : rest;
};

test('Stable candidates build Sparkle first and iOS never gates it', () => {
  const ios = job(read('prepare-stable.yml'), 'ios');
  assert.match(ios, /needs: \[prepare, mac-direct\]/);
  assert.match(ios, /!cancelled\(\) && needs\.prepare\.result == 'success'/);
});

test('Publish Stable submits iOS best effort; the reconciler finishes it later', () => {
  const workflow = read('publish-stable.yml');
  const submit = job(workflow, 'submit-apple');
  assert.match(submit, /continue-on-error: true/);
  assert.match(submit, /release-apple\.rb submit-if-ready /);
  assert.doesNotMatch(job(workflow, 'publish'), /release-apple\.rb/);
  assert.match(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../reconcile-apple-releases.rb'), 'utf8'), /submit_if_ready if manifest\.equal\?\(approved_stable\)/);
});

test('Alpha retries rebuild only surfaces still awaiting delivery', () => {
  const workflow = read('alpha-release.yml');
  const allocate = job(workflow, 'allocate');
  assert.match(allocate, /release-train\.mjs plan --tag/);
  assert.match(allocate, /if: steps\.plan\.outputs\.publish_alpha == 'true'\n\s+env:[\s\S]*?release-train\.mjs publish-alpha --tag/);
  assert.match(job(workflow, 'mac-direct'), /needs\.allocate\.outputs\.mac_direct == 'true'/);
  const ios = job(workflow, 'ios');
  assert.match(ios, /needs: \[allocate, mac-direct\]/);
  assert.match(ios, /!cancelled\(\) && .*needs\.allocate\.outputs\.ios == 'true'/);
});

test('the iOS lane can be retried alone, only by the owner on main', () => {
  const workflow = read('release-ios.yml');
  assert.match(workflow, /\n  workflow_dispatch:\n    inputs:\n      manifest:/);
  assert.match(job(workflow, 'preflight'), /github\.workflow != 'Release iOS \(TestFlight\)' \|\| \(github\.actor == github\.repository_owner && github\.ref == 'refs\/heads\/main'\)/);
  assert.match(job(workflow, 'testflight'), /needs: preflight/);
});
