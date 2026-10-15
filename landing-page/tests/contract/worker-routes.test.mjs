import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import worker, {archFromClientHints} from '../../_worker.js';

const RELEASES = 'https://github.com/crmitchelmore/pasta/releases';
const APPCAST = `<?xml version="1.0"?><rss><channel><item><title>1.10.0</title>
<enclosure url="${RELEASES}/download/v1.10.0/Pasta-1.10.0.dmg" sparkle:version="40" length="8080000" type="application/octet-stream"/>
</item><item><enclosure url="${RELEASES}/download/v1.9.0/Pasta-1.9.0.dmg"/></item></channel></rss>`;

function site(appcast = APPCAST) {
  const requests = [];
  return {
    requests,
    env: {ASSETS: {fetch: async (request) => {
      requests.push(new URL(request.url).pathname);
      return new URL(request.url).pathname === '/appcast.xml' ? new Response(appcast) : new Response('static');
    }}},
  };
}

// Stubs GitHub: HEAD of an existing asset answers 302 to its storage URL, a missing one 404.
function github(t, {assets = [], pointer = {tag: 'alpha-build-42', version: '1.11.0'}} = {}) {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, init = {}) => {
    calls.push({url: String(url), method: init.method ?? 'GET'});
    if (String(url).endsWith('/alpha-latest/alpha-pointer.json')) return Response.json(pointer);
    if (init.method === 'HEAD') {
      assert.equal(init.redirect, 'manual', 'asset probes must not follow GitHub storage redirects');
      return new Response(null, assets.includes(String(url)) ? {status: 302, headers: {Location: 'https://objects.example/x'}} : {status: 404});
    }
    throw new Error(`unexpected fetch ${url}`);
  });
  return calls;
}

const get = (path, headers = {}, env = site().env) => worker.fetch(new Request(`https://pasta-app.com${path}`, {headers}), env);
const MAC_ARM = {'Sec-CH-UA-Platform': '"macOS"', 'Sec-CH-UA-Arch': '"arm"'};
const MAC_X86 = {'Sec-CH-UA-Platform': '"macOS"', 'Sec-CH-UA-Arch': '"x86"'};
const THIN_ARM = `${RELEASES}/download/v1.10.0/Pasta-1.10.0-AppleSilicon.dmg`;
const THIN_INTEL = `${RELEASES}/download/v1.10.0/Pasta-1.10.0-Intel.dmg`;
const UNIVERSAL = `${RELEASES}/download/v1.10.0/Pasta-1.10.0.dmg`;

test('the worker only claims download and Alpha routes; everything else is static', async (t) => {
  const routes = JSON.parse(readFileSync(new URL('../../_routes.json', import.meta.url)));
  assert.deepEqual(routes.include, ['/alpha/*', '/download', '/download/*']);
  github(t);
  const {env, requests} = site();
  for (const path of ['/', '/appcast.xml', '/styles.css', '/downloads', '/download/arm64', '/alpha/other']) {
    assert.equal(await (await get(path, {}, env)).text(), path === '/appcast.xml' ? APPCAST : 'static', path);
  }
  assert.deepEqual(requests, ['/', '/appcast.xml', '/styles.css', '/downloads', '/download/arm64', '/alpha/other']);
});

test('/download without a detectable chip serves the universal DMG named by the live appcast', async (t) => {
  const calls = github(t, {assets: [THIN_ARM, THIN_INTEL]});
  for (const headers of [{}, {'Sec-CH-UA-Platform': '"Windows"', 'Sec-CH-UA-Arch': '"arm"'}, {'Sec-CH-UA-Platform': '"macOS"'}]) {
    const response = await get('/download', headers);
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('Location'), UNIVERSAL);
    assert.equal(response.headers.get('Accept-CH'), 'Sec-CH-UA-Arch');
    assert.match(response.headers.get('Vary'), /Sec-CH-UA-Arch/);
    assert.match(response.headers.get('Cache-Control'), /^private/);
  }
  assert.deepEqual(calls, [], 'no asset probe is needed for the universal DMG');
});

test('/download picks the thin DMG for the chip Chromium reports', async (t) => {
  github(t, {assets: [THIN_ARM, THIN_INTEL]});
  assert.equal((await get('/download', MAC_ARM)).headers.get('Location'), THIN_ARM);
  assert.equal((await get('/download/', MAC_X86)).headers.get('Location'), THIN_INTEL);
});

test('explicit chip routes serve thin DMGs and are cacheable', async (t) => {
  github(t, {assets: [THIN_ARM, THIN_INTEL]});
  const arm = await get('/download/apple-silicon', MAC_X86);
  assert.equal(arm.status, 302);
  assert.equal(arm.headers.get('Location'), THIN_ARM, 'an explicit choice beats client hints');
  assert.equal(arm.headers.get('Cache-Control'), 'public, max-age=30');
  assert.equal(arm.headers.get('Vary'), null);
  assert.equal((await get('/download/intel')).headers.get('Location'), THIN_INTEL);
});

test('releases without thin DMGs fall back to the universal DMG', async (t) => {
  github(t, {assets: []});
  for (const [path, headers] of [['/download/apple-silicon', {}], ['/download/intel', {}], ['/download', MAC_ARM]]) {
    assert.equal((await get(path, headers)).headers.get('Location'), UNIVERSAL, path);
  }
});

test('an unreachable asset probe falls back to the universal DMG', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => { throw new TypeError('network down'); });
  assert.equal((await get('/download/intel')).headers.get('Location'), UNIVERSAL);
});

test('an unreadable appcast sends visitors to the latest GitHub release', async (t) => {
  github(t);
  for (const appcast of ['', '<rss><enclosure url="https://example.com/evil.dmg"/></rss>',
    `<rss><enclosure url="${RELEASES}/download/v1.10.0/Pasta-1.9.0.dmg"/></rss>`]) {
    const response = await get('/download/apple-silicon', {}, site(appcast).env);
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('Location'), `${RELEASES}/latest`);
  }
});

test('Alpha downloads use the pointer and the same chip fallback', async (t) => {
  const alpha = `${RELEASES}/download/alpha-build-42`;
  github(t, {assets: [`${alpha}/Pasta-Alpha-1.11.0-AppleSilicon.dmg`]});
  assert.equal((await get('/alpha/download')).headers.get('Location'), `${alpha}/Pasta-Alpha-1.11.0.dmg`);
  assert.equal((await get('/alpha/download', MAC_ARM)).headers.get('Location'), `${alpha}/Pasta-Alpha-1.11.0-AppleSilicon.dmg`);
  assert.equal((await get('/alpha/download/apple-silicon')).headers.get('Location'), `${alpha}/Pasta-Alpha-1.11.0-AppleSilicon.dmg`);
  assert.equal((await get('/alpha/download/intel')).headers.get('Location'), `${alpha}/Pasta-Alpha-1.11.0.dmg`);
  assert.equal((await get('/alpha/appcast.xml')).headers.get('Location'), `${alpha}/appcast.xml`);
});

test('malformed Alpha pointers are rejected', async (t) => {
  for (const pointer of [{tag: 'v1.9.0', version: '1.9.0'}, {tag: 'alpha-build-1', version: '../x'}]) {
    t.mock.restoreAll();
    github(t, {pointer});
    assert.equal((await get('/alpha/appcast.xml')).status, 503);
    assert.equal((await get('/alpha/download/intel')).status, 503);
  }
});

test('client hints only identify Macs that report a known architecture', () => {
  const hints = (values) => new Headers(values);
  assert.equal(archFromClientHints(hints(MAC_ARM)), 'apple-silicon');
  assert.equal(archFromClientHints(hints(MAC_X86)), 'intel');
  assert.equal(archFromClientHints(hints({'Sec-CH-UA-Platform': '"macOS"', 'Sec-CH-UA-Arch': '""'})), null);
  assert.equal(archFromClientHints(hints({'Sec-CH-UA-Platform': '"Linux"', 'Sec-CH-UA-Arch': '"x86"'})), null);
  assert.equal(archFromClientHints(hints({})), null);
});
