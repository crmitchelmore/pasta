import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

function assertPinnedReference(reference, location) {
  if (reference.startsWith('./')) {
    assert.match(reference, /^\.\/[^@\s]+$/, location);
  } else if (reference.startsWith('docker://')) {
    assert.match(reference, /^docker:\/\/[^@\s]+@sha256:[a-f0-9]{64}$/, location);
  } else {
    assert.match(reference, /^[^@\s]+@[a-f0-9]{40}$/, location);
  }
}

test('action pin policy allows local actions and immutable remote references', () => {
  for (const reference of [
    './.github/actions/build',
    './.github/workflows/release.yml',
    `actions/checkout@${'a'.repeat(40)}`,
    `owner/repo/path/to/action@${'b'.repeat(40)}`,
    `owner/repo/.github/workflows/build.yml@${'c'.repeat(40)}`,
    `docker://alpine@sha256:${'d'.repeat(64)}`,
  ]) {
    assertPinnedReference(reference, reference);
  }
});

test('action pin policy rejects tags, branches, short SHAs and unpinned images', () => {
  for (const reference of [
    'actions/checkout@v7.0.1',
    'actions/checkout@main',
    'actions/checkout@3d3c42e',
    'actions/checkout',
    'owner/repo/.github/workflows/build.yml@main',
    'docker://alpine:3.22',
    `docker://alpine@${'a'.repeat(40)}`,
  ]) {
    assert.throws(() => assertPinnedReference(reference, reference), assert.AssertionError);
  }
});

const workflows = new URL('../../.github/workflows/', import.meta.url);
for (const file of readdirSync(workflows).filter(name => /\.ya?ml$/.test(name)).sort()) {
  test(`${file} uses only immutable action and reusable workflow references`, () => {
    const content = readFileSync(new URL(file, workflows), 'utf8');
    for (const [index, line] of content.split('\n').entries()) {
      const match = line.match(/^\s*(?:-\s*)?uses:\s*(.+)$/);
      if (!match) continue;
      const reference = match[1].replace(/\s+#.*$/, '').trim().replace(/^(["'])(.*)\1$/, '$2');
      assertPinnedReference(reference, `${file}:${index + 1}: ${reference} must use a full commit SHA or image digest`);
    }
  });
}
