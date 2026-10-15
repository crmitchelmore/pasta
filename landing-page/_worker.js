// Download routes plus README-only Alpha routes. The website's other routes are static assets.
//
//   /download                    Stable DMG for the visitor's chip (client hints), else universal
//   /download/apple-silicon      Stable Apple Silicon DMG
//   /download/intel              Stable Intel DMG
//   /alpha/download[...]         the same for the newest Alpha build
//   /alpha/appcast.xml           Alpha Sparkle feed
//
// Sparkle updates always use the universal DMG from the appcast. Per-architecture DMGs exist only
// for releases built after the split, so every architecture route falls back to the universal DMG.

const RELEASES = 'https://github.com/crmitchelmore/pasta/releases';
const DOWNLOAD_ROUTE = /^\/(alpha\/)?download(?:\/(apple-silicon|intel))?\/?$/;
const ARCH_SUFFIX = {'apple-silicon': 'AppleSilicon', intel: 'Intel'};
// The newest Stable item is first in the deployed appcast; release.yml names DMGs Pasta-<version>.dmg.
const STABLE_ENCLOSURE = /<enclosure\b[^>]*?\burl="https:\/\/github\.com\/crmitchelmore\/pasta\/releases\/download\/v(\d+\.\d+\.\d+)\/Pasta-\1\.dmg"/;

const unquote = (value) => (value ?? '').trim().replace(/^"|"$/g, '');

// Chromium sends Sec-CH-UA-Arch once a page has opted in with Accept-CH (see _headers).
export function archFromClientHints(headers) {
  if (unquote(headers.get('Sec-CH-UA-Platform')) !== 'macOS') return null;
  const arch = unquote(headers.get('Sec-CH-UA-Arch')).toLowerCase();
  return arch === 'arm' ? 'apple-silicon' : arch === 'x86' ? 'intel' : null;
}

const redirect = (location, headers = {}) => new Response(null, {status: 302, headers: {
  Location: location, 'Cache-Control': 'public, max-age=30', ...headers,
}});

async function alphaPointer() {
  const result = await fetch(`${RELEASES}/download/alpha-latest/alpha-pointer.json`, {
    cf: {cacheTtl: 30}, headers: {Accept: 'application/json'},
  });
  if (!result.ok) return new Response('Alpha is not available yet', {status: 503});
  const pointer = await result.json();
  if (!/^alpha-build-[1-9][0-9]*$/.test(pointer.tag) || !/^\d+\.\d+\.\d+$/.test(pointer.version)) {
    return new Response('Invalid Alpha pointer', {status: 503});
  }
  return pointer;
}

async function stableVersion(request, env) {
  const response = await env.ASSETS.fetch(new Request(new URL('/appcast.xml', request.url)));
  if (!response.ok) return null;
  return STABLE_ENCLOSURE.exec(await response.text())?.[1] ?? null;
}

async function assetExists(url) {
  try {
    const response = await fetch(url, {method: 'HEAD', redirect: 'manual', signal: AbortSignal.timeout(3000)});
    return response.status >= 200 && response.status < 400;
  } catch {
    return false;
  }
}

async function download(request, env, alpha, requestedArch) {
  let tag, base;
  if (alpha) {
    const pointer = await alphaPointer();
    if (pointer instanceof Response) return pointer;
    // release.yml names the DMG with spaces replaced by hyphens.
    tag = pointer.tag;
    base = `Pasta-Alpha-${pointer.version}`;
  } else {
    const version = await stableVersion(request, env);
    if (!version) return redirect(`${RELEASES}/latest`);
    tag = `v${version}`;
    base = `Pasta-${version}`;
  }

  const automatic = !requestedArch;
  const arch = requestedArch ?? archFromClientHints(request.headers);
  // A detected download depends on request headers, so it must not be shared between visitors.
  const headers = automatic
    ? {'Accept-CH': 'Sec-CH-UA-Arch', Vary: 'Sec-CH-UA-Arch, Sec-CH-UA-Platform', 'Cache-Control': 'private, max-age=30'}
    : {};
  const universal = `${RELEASES}/download/${tag}/${encodeURIComponent(`${base}.dmg`)}`;
  if (arch) {
    const thin = `${RELEASES}/download/${tag}/${encodeURIComponent(`${base}-${ARCH_SUFFIX[arch]}.dmg`)}`;
    if (await assetExists(thin)) return redirect(thin, headers);
  }
  return redirect(universal, headers);
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const route = DOWNLOAD_ROUTE.exec(path);
    if (route) return download(request, env, Boolean(route[1]), route[2] ?? null);
    if (path !== '/alpha/appcast.xml') return env.ASSETS.fetch(request);
    const pointer = await alphaPointer();
    if (pointer instanceof Response) return pointer;
    return redirect(`${RELEASES}/download/${pointer.tag}/appcast.xml`);
  },
};
