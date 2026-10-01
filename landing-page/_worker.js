// README-only Alpha routes. The website's existing routes always remain Stable.
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!['/alpha/appcast.xml', '/alpha/download'].includes(path)) return env.ASSETS.fetch(request);
    const result = await fetch('https://github.com/crmitchelmore/pasta/releases/download/alpha-latest/alpha-pointer.json', {
      cf: {cacheTtl: 30}, headers: {Accept: 'application/json'},
    });
    if (!result.ok) return new Response('Alpha is not available yet', {status: 503});
    const pointer = await result.json();
    if (!/^alpha-build-[1-9][0-9]*$/.test(pointer.tag) || !/^\d+\.\d+\.\d+$/.test(pointer.version)) {
      return new Response('Invalid Alpha pointer', {status: 503});
    }
    const asset = path.endsWith('appcast.xml') ? 'appcast.xml' : `Pasta Alpha-${pointer.version}.dmg`;
    return new Response(null, {status: 302, headers: {
      Location: `https://github.com/crmitchelmore/pasta/releases/download/${pointer.tag}/${encodeURIComponent(asset)}`,
      'Cache-Control': 'public, max-age=30',
    }});
  },
};
