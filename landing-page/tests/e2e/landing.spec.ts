import AxeBuilder from '@axe-core/playwright';
import { expect, test } from './fixtures';

const REPO_URL = 'https://github.com/crmitchelmore/pasta';

// Primary download buttons go to the site's /download route, which redirects straight to a DMG
// (see _worker.js). download.js swaps in the chip-specific route when it can identify the Mac.
const DOWNLOAD_ROUTE = /^\/download(\/apple-silicon|\/intel)?$/;
const GITHUB_RELEASE =
  /^https:\/\/github\.com\/crmitchelmore\/pasta\/releases\/(latest|download\/v(\d+\.\d+\.\d+)\/Pasta-(\d+\.\d+\.\d+)\.dmg)$/;

function assertWellFormedDownloadUrl(href: string) {
  const url = new URL(href);
  if (url.hostname === '127.0.0.1' || url.hostname === 'localhost') {
    expect(url.pathname, `download href should use the /download route: ${href}`).toMatch(DOWNLOAD_ROUTE);
    return;
  }
  const match = GITHUB_RELEASE.exec(href);
  expect(match, `download href should point at a GitHub release: ${href}`).not.toBeNull();
  const [, , tagVersion, fileVersion] = match!;
  if (tagVersion) {
    expect(fileVersion, `DMG file version must match its tag in ${href}`).toBe(tagVersion);
  }
}

// Simulates the browser's chip report before download.js runs.
async function emulateMac(page: import('@playwright/test').Page, hint: { platform: string; architecture?: string } | { renderer: string; astc?: boolean }) {
  await page.addInitScript((hint) => {
    if ('platform' in hint) {
      Object.defineProperty(navigator, 'userAgentData', {
        configurable: true,
        value: { platform: hint.platform, getHighEntropyValues: async () => ({ architecture: hint.architecture ?? '' }) },
      });
      return;
    }
    Object.defineProperty(navigator, 'userAgentData', { configurable: true, value: undefined });
    Object.defineProperty(navigator, 'userAgent', { configurable: true, value: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15' });
    Object.defineProperty(navigator, 'maxTouchPoints', { configurable: true, value: 0 });
    const RENDERER = 0x9246;
    const original = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (this: HTMLCanvasElement, type: string, ...rest: unknown[]) {
      if (type !== 'webgl') return original.call(this, type, ...rest);
      return {
        getExtension: (name: string) =>
          name === 'WEBGL_debug_renderer_info' ? { UNMASKED_RENDERER_WEBGL: RENDERER }
            : name === 'WEBGL_compressed_texture_astc' ? (hint.astc ? {} : null)
              : name === 'WEBGL_lose_context' ? { loseContext() {} } : null,
        getParameter: (parameter: number) => (parameter === RENDERER ? hint.renderer : null),
      };
    } as typeof original;
  }, hint);
}

const PRIMARY_CTAS = ['nav .nav__cta', '.hero__actions .btn--primary', '#download .btn--primary'];

test.describe('landing page renders', () => {
  test('title, hero and primary sections are present', async ({ page }) => {
    await page.goto('/');

    await expect(page).toHaveTitle(/Pasta/);
    await expect(page).toHaveTitle(/Al Dente/i);

    const heading = page.getByRole('heading', { level: 1 });
    await expect(heading).toBeVisible();
    await expect(heading).toContainText(/your clipboard/i);
    await expect(heading).toContainText(/al dente/i);

    await expect(page.locator('.hero__subtitle')).toContainText(/clipboard history manager for macOS/i);
    await expect(page.locator('#download')).toBeAttached();
    await expect(page.locator('#download .download__requirements')).toContainText(/macOS 14/);
  });

  test('loads without console errors, page errors or failed requests', async ({ page, consoleErrors }) => {
    await page.goto('/', { waitUntil: 'load' });
    // Give lazy work (IntersectionObserver callbacks, image decoding) a beat.
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 100))));

    expect(consoleErrors.pageErrors, 'uncaught page errors').toEqual([]);
    expect(consoleErrors.console, 'console.error output').toEqual([]);
    expect(consoleErrors.failedRequests, 'failed same-origin requests').toEqual([]);
  });

  test('only talks to the expected third parties', async ({ page, offlineStubs }) => {
    await page.goto('/', { waitUntil: 'load' });
    const hosts = new Set(offlineStubs.stubbed.map((url) => new URL(url).host));
    // The font CDN is the only external dependency of the page. Anything else
    // (analytics, trackers) showing up here is a privacy regression.
    expect([...hosts].sort()).toEqual(['api.fontshare.com']);
  });

  test('does not overflow horizontally on desktop or mobile', async ({ page }) => {
    for (const viewport of [
      { width: 1280, height: 800 },
      { width: 390, height: 844 },
    ]) {
      await page.setViewportSize(viewport);
      await page.goto('/', { waitUntil: 'load' });
      const { scrollWidth, clientWidth } = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      }));
      expect(scrollWidth, `horizontal overflow at ${viewport.width}px`).toBeLessThanOrEqual(clientWidth);
    }
  });
});

test.describe('calls to action', () => {
  test('every download CTA uses the direct download route', async ({ page }) => {
    await page.goto('/');

    const downloadLinks = page.getByRole('link', { name: /download/i });
    expect(await downloadLinks.count(), 'download CTAs on the page').toBeGreaterThanOrEqual(3);

    for (const href of await downloadLinks.evaluateAll((links) => links.map((a) => (a as HTMLAnchorElement).href))) {
      assertWellFormedDownloadUrl(href);
    }

    // The three canonical placements: nav, hero, closing download section.
    for (const selector of PRIMARY_CTAS) {
      await expect(page.locator(selector)).toHaveAttribute('href', DOWNLOAD_ROUTE);
    }
  });

  test('both chip-specific downloads are always offered', async ({ page }) => {
    await page.goto('/');
    for (const section of ['.hero__copy', '#download']) {
      await expect(page.locator(section).getByRole('link', { name: 'Apple Silicon', exact: true })).toHaveAttribute('href', '/download/apple-silicon');
      await expect(page.locator(section).getByRole('link', { name: 'Intel', exact: true })).toHaveAttribute('href', '/download/intel');
    }
  });

  const detections = [
    { name: 'Chromium on Apple Silicon', hint: { platform: 'macOS', architecture: 'arm' }, arch: 'apple-silicon', label: 'Download for Apple Silicon' },
    { name: 'Chromium on Intel', hint: { platform: 'macOS', architecture: 'x86' }, arch: 'intel', label: 'Download for Intel Mac' },
    { name: 'Safari on Apple Silicon', hint: { renderer: 'Apple GPU', astc: true }, arch: 'apple-silicon', label: 'Download for Apple Silicon' },
    { name: 'Firefox on Apple Silicon', hint: { renderer: 'Apple M2 Pro' }, arch: 'apple-silicon', label: 'Download for Apple Silicon' },
    { name: 'Safari on Intel', hint: { renderer: 'Intel(R) Iris(TM) Plus Graphics' }, arch: 'intel', label: 'Download for Intel Mac' },
  ];
  for (const { name, hint, arch, label } of detections) {
    test(`detects ${name} and offers its build by default`, async ({ page }) => {
      await emulateMac(page, hint);
      await page.goto('/');
      for (const selector of PRIMARY_CTAS) {
        await expect(page.locator(selector)).toHaveAttribute('href', `/download/${arch}`);
      }
      await expect(page.locator('.hero__actions .btn--primary')).toContainText(label);
      await expect(page.locator('#download .btn--primary')).toContainText(label);
    });
  }

  for (const { name, hint } of [
    { name: 'a non-Mac', hint: { platform: 'Windows', architecture: 'x86' } },
    { name: 'a Mac that hides its chip', hint: { renderer: 'Apple GPU' } },
  ]) {
    test(`keeps the universal download for ${name}`, async ({ page }) => {
      await emulateMac(page, hint);
      await page.goto('/');
      await page.waitForFunction(() => document.readyState === 'complete');
      await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 50)));
      for (const selector of PRIMARY_CTAS) {
        await expect(page.locator(selector)).toHaveAttribute('href', '/download');
      }
      await expect(page.locator('.hero__actions .btn--primary')).toContainText('Download for Mac');
    });
  }

  test('GitHub CTAs point at the repository', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('navigation').getByRole('link', { name: 'GitHub' })).toHaveAttribute('href', REPO_URL);
    await expect(page.locator('.hero__actions .btn--secondary')).toHaveAttribute('href', REPO_URL);
    await expect(page.locator('#download .btn--secondary')).toHaveAttribute('href', REPO_URL);

    const footer = page.getByRole('contentinfo');
    await expect(footer.getByRole('link', { name: 'GitHub' })).toHaveAttribute('href', REPO_URL);
    await expect(footer.getByRole('link', { name: 'Releases' })).toHaveAttribute('href', `${REPO_URL}/releases`);
    await expect(footer.getByRole('link', { name: 'Issues' })).toHaveAttribute('href', `${REPO_URL}/issues`);
  });

  test('all hrefs are well-formed and in-page anchors resolve', async ({ page }) => {
    await page.goto('/');

    const links = await page.locator('a[href]').evaluateAll((anchors) =>
      anchors.map((a) => ({
        raw: a.getAttribute('href') ?? '',
        resolved: (a as HTMLAnchorElement).href,
        target: a.getAttribute('target'),
        rel: a.getAttribute('rel') ?? '',
        text: (a.textContent ?? '').trim().replace(/\s+/g, ' ').slice(0, 60),
      })),
    );
    expect(links.length).toBeGreaterThan(10);

    const ids = new Set(await page.locator('[id]').evaluateAll((els) => els.map((el) => el.id)));

    for (const link of links) {
      expect(link.raw, `empty href on "${link.text}"`).not.toBe('');
      expect(link.raw, `placeholder href on "${link.text}"`).not.toMatch(/^(#|javascript:)$/);

      if (link.raw.startsWith('#')) {
        expect(ids.has(link.raw.slice(1)), `anchor ${link.raw} ("${link.text}") has no target element`).toBe(true);
        continue;
      }

      const url = new URL(link.resolved); // throws on malformed URLs
      if (url.protocol === 'https:' || url.protocol === 'http:') {
        if (url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') {
          expect(url.protocol, `external link must use https: ${link.raw}`).toBe('https:');
        }
      } else {
        expect(['mailto:'], `unexpected protocol in ${link.raw}`).toContain(url.protocol);
      }

      if (link.target === '_blank') {
        expect(link.rel.split(/\s+/), `target=_blank without rel=noopener: ${link.raw}`).toContain('noopener');
      }
    }
  });
});

test.describe('assets', () => {
  test('every <img> and icon resolves and renders', async ({ page }) => {
    await page.goto('/', { waitUntil: 'load' });

    const images = await page.locator('img').evaluateAll((imgs) =>
      imgs.map((img) => {
        const el = img as HTMLImageElement;
        return { src: el.currentSrc || el.src, lazy: el.loading === 'lazy', complete: el.complete, naturalWidth: el.naturalWidth };
      }),
    );
    expect(images.length).toBeGreaterThanOrEqual(3);

    for (const image of images) {
      const response = await page.request.get(image.src);
      expect(response.status(), `${image.src} should be served`).toBe(200);
      expect(response.headers()['content-type'], `${image.src} content type`).toMatch(/^image\//);
      expect((await response.body()).byteLength, `${image.src} should not be empty`).toBeGreaterThan(0);
      if (!image.lazy) {
        expect(image.complete && image.naturalWidth > 0, `${image.src} should have decoded`).toBe(true);
      }
    }

    const icons = await page
      .locator('link[rel~="icon"], link[rel="apple-touch-icon"]')
      .evaluateAll((links) => links.map((l) => (l as HTMLLinkElement).href));
    expect(icons.length).toBeGreaterThanOrEqual(2);
    for (const href of icons) {
      const response = await page.request.get(href);
      expect(response.status(), `${href} should be served`).toBe(200);
    }
  });

  test('appcast.xml is served alongside the page', async ({ request }) => {
    const response = await request.get('/appcast.xml');
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toMatch(/xml/);
    expect(await response.text()).toContain('<rss');
  });
});

test.describe('accessibility', () => {
  test('document structure: lang, single h1, landmarks, alt text', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('lang', /^[a-z]{2}/);
    await expect(page.getByRole('heading', { level: 1 })).toHaveCount(1);
    await expect(page.getByRole('navigation')).toHaveCount(1);
    await expect(page.getByRole('main')).toHaveCount(1);
    await expect(page.getByRole('contentinfo')).toHaveCount(1);

    const missingAlt = await page
      .locator('img')
      .evaluateAll((imgs) => imgs.filter((img) => !(img.getAttribute('alt') ?? '').trim()).map((img) => img.getAttribute('src')));
    expect(missingAlt, 'images without alt text').toEqual([]);
  });

  test('axe-core: no WCAG 2.0/2.1 A or AA violations', async ({ page }) => {
    // Audit final colours without sampling the coordinated hero entrance mid-frame.
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto('/', { waitUntil: 'load' });

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();

    const summary = results.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      help: v.help,
      nodes: v.nodes.slice(0, 5).map((n) => n.target.join(' ')),
    }));
    expect(summary, JSON.stringify(summary, null, 2)).toEqual([]);
  });
});

test('release highlights and roadmap remain distinct and keyboard accessible', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('navigation').getByRole('link', { name: 'What’s cooking' }).click();
  await expect(page).toHaveURL(/#whats-new$/);
  const updates = page.locator('#whats-new');
  await expect(updates.getByRole('link', { name: /1.6.2/ })).toHaveAttribute('href', `${REPO_URL}/releases/tag/v1.6.2`);
  await expect(updates.getByRole('link', { name: /1.6.0/ })).toHaveAttribute('href', `${REPO_URL}/releases/tag/v1.6.0`);
  const sharing = page.locator('#roadmap details').first();
  await expect(sharing).not.toHaveAttribute('open');
  await sharing.locator('summary').focus();
  await page.keyboard.press('Enter');
  await expect(sharing).toHaveAttribute('open', '');
  await expect(sharing).toContainText('This isn’t available yet.');
  await page.keyboard.press('Enter');
  await expect(sharing).not.toHaveAttribute('open');
  const shortcuts = page.locator('#shortcuts details');
  await shortcuts.locator('summary').click();
  await expect(shortcuts.getByText('Paste as plain text')).toBeVisible();
});

test('motion settles, responds to hover, and stops for reduced motion', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await page.goto('/');
  const capture = page.locator('.hero__visual');
  await expect(capture).toHaveCSS('animation-name', 'clipboard-arrives');
  await expect(capture).toHaveCSS('opacity', '1');
  const image = capture.locator('img');
  await image.hover();
  await expect(image).toHaveCSS('transform', 'matrix(1, 0, 0, 1, 0, -6)');

  // A preference change must stop motion immediately, without hiding content.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(capture).toHaveCSS('animation-name', 'none');
  await expect(capture).toHaveCSS('opacity', '1');
  await expect(image).toHaveCSS('transform', 'none');
  await expect(image).toHaveCSS('transition-duration', '0s');
  await expect(page.locator('.hero__title')).toHaveCSS('animation-name', 'none');
  await page.locator('#roadmap summary').first().click();
  await expect(page.locator('#roadmap details').first()).toHaveAttribute('open', '');
  await expect(page.locator('#roadmap details p').first()).toHaveCSS('animation-name', 'none');
});
