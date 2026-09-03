import AxeBuilder from '@axe-core/playwright';
import { expect, test } from './fixtures';

const REPO_URL = 'https://github.com/crmitchelmore/pasta';

// Every "Download" call to action must send users to a GitHub release: either
// the evergreen `releases/latest` page or a pinned DMG asset whose file name
// carries the same version as its tag.
const DOWNLOAD_URL =
  /^https:\/\/github\.com\/crmitchelmore\/pasta\/releases\/(latest|download\/v(\d+\.\d+\.\d+)\/Pasta-(\d+\.\d+\.\d+)\.dmg)$/;

function assertWellFormedDownloadUrl(href: string) {
  const match = DOWNLOAD_URL.exec(href);
  expect(match, `download href should point at a GitHub release: ${href}`).not.toBeNull();
  const [, , tagVersion, fileVersion] = match!;
  if (tagVersion) {
    expect(fileVersion, `DMG file version must match its tag in ${href}`).toBe(tagVersion);
  }
}

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
  test('every download CTA points at a GitHub release', async ({ page }) => {
    await page.goto('/');

    const downloadLinks = page.getByRole('link', { name: /download/i });
    expect(await downloadLinks.count(), 'download CTAs on the page').toBeGreaterThanOrEqual(3);

    for (const href of await downloadLinks.evaluateAll((links) => links.map((a) => (a as HTMLAnchorElement).href))) {
      assertWellFormedDownloadUrl(href);
    }

    // The three canonical placements: nav, hero, closing download section.
    await expect(page.locator('nav .nav__cta')).toHaveAttribute('href', DOWNLOAD_URL);
    await expect(page.locator('.hero__actions .btn--primary')).toHaveAttribute('href', DOWNLOAD_URL);
    await expect(page.locator('#download .btn--primary')).toHaveAttribute('href', DOWNLOAD_URL);
  });

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
    // The scroll-reveal `.fade-in` elements start at opacity 0 and fade in over
    // 0.45s, so axe's color-contrast check can sample them mid-transition on a
    // slow runner. The page honours prefers-reduced-motion by rendering them
    // fully opaque with no transition; emulate it so the audit measures the
    // real final colours deterministically.
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
