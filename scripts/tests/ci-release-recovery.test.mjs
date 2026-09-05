import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { draftAttemptedRelease } from '../ci-draft-release.mjs';

function recoveryFixture({ draft = false, lookupError, updateError } = {}) {
  const updates = [];
  const github = { rest: { repos: {
    getReleaseByTag: async (args) => {
      assert.deepEqual(args, { owner: 'owner', repo: 'repo', tag: 'v1.2.3' });
      if (lookupError) throw lookupError;
      return { data: { id: 42, draft } };
    },
    updateRelease: async (args) => {
      updates.push(args);
      if (updateError) throw updateError;
      return { data: { id: 42, draft: true } };
    },
  } } };
  return { updates, args: { github, owner: 'owner', repo: 'repo', tag: 'v1.2.3' } };
}

test('cleanup drafts external release left public by partial publication or cancellation', async () => {
  // An unsuccessful publishing action can leave exactly this API state.
  const { args, updates } = recoveryFixture();
  assert.equal(await draftAttemptedRelease(args), 'drafted');
  assert.deepEqual(updates, [{ owner: 'owner', repo: 'repo', release_id: 42, draft: true }]);
});

test('failed publication with no release and repeated cleanup are harmless', async () => {
  for (const [options, result] of [
    [{ lookupError: Object.assign(new Error('not found'), { status: 404 }) }, 'absent'],
    [{ draft: true }, 'already-draft'],
  ]) {
    const { args, updates } = recoveryFixture(options);
    assert.equal(await draftAttemptedRelease(args), result);
    assert.deepEqual(updates, []);
  }
});

test('cleanup fails loudly when API lookup or drafting is unavailable', async () => {
  for (const status of [401, 403, 429, 500]) {
    const { args } = recoveryFixture({ lookupError: Object.assign(new Error('API failed'), { status }) });
    await assert.rejects(draftAttemptedRelease(args), /Cannot determine whether v1.2.3 is public/);
  }
  const { args } = recoveryFixture({ updateError: new Error('write denied') });
  await assert.rejects(draftAttemptedRelease(args), /Could not draft v1.2.3/);
});

test('Homebrew publication can be retried without failing or adding duplicate commits', () => {
  const root = mkdtempSync(join(tmpdir(), 'pasta-tap-recovery-'));
  const remote = join(root, 'tap.git');
  const tap = join(root, 'tap');
  const script = fileURLToPath(new URL('../ci-commit-homebrew.sh', import.meta.url));
  const git = (args, cwd = root) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const publish = (version) => execFileSync('bash', [script, version], { cwd: tap, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    git(['init', '--bare', remote]);
    git(['clone', remote, tap]);
    git(['config', 'user.name', 'Test'], tap);
    git(['config', 'user.email', 'test@example.invalid'], tap);
    mkdirSync(join(tap, 'Casks'));
    const cask = join(tap, 'Casks/pasta.rb');
    writeFileSync(cask, 'version "1.2.3"\nsha256 "first"\n');
    publish('1.2.3');
    const first = git(['rev-parse', 'HEAD'], tap);
    assert.match(publish('1.2.3'), /already matches/);
    assert.equal(git(['rev-parse', 'HEAD'], tap), first);
    assert.equal(git(['rev-parse', 'HEAD'], remote), first);
    writeFileSync(cask, 'version "1.2.4"\nsha256 "second"\n');
    publish('1.2.4');
    assert.notEqual(git(['rev-parse', 'HEAD'], tap), first);
    assert.equal(git(['rev-parse', 'HEAD'], remote), git(['rev-parse', 'HEAD'], tap));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
