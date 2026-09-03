import { test as base, expect } from '@playwright/test';

/**
 * Shared fixtures for the landing page smoke suite.
 *
 * - `offlineStubs`: every request that is not for the local static server is
 *   answered with an empty 200 so the suite runs without network access and
 *   third-party outages (font CDN, GitHub) can never fail it. Stubbed URLs are
 *   recorded so tests can still assert *which* third parties the page talks to.
 * - `consoleErrors`: collects console errors, uncaught page errors and failed
 *   same-origin requests so tests can assert the page loads cleanly.
 */

export type ConsoleErrors = {
  console: string[];
  pageErrors: string[];
  failedRequests: string[];
};

type Fixtures = {
  offlineStubs: { stubbed: string[] };
  consoleErrors: ConsoleErrors;
};

const EMPTY_BODY_BY_TYPE: Record<string, { contentType: string; body: string }> = {
  stylesheet: { contentType: 'text/css', body: '' },
  script: { contentType: 'text/javascript', body: '' },
  font: { contentType: 'font/woff2', body: '' },
  image: { contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg"/>' },
};

export const test = base.extend<Fixtures>({
  offlineStubs: [
    async ({ page, baseURL }, use) => {
      const local = new URL(baseURL ?? 'http://127.0.0.1');
      const stubbed: string[] = [];
      await page.route('**/*', async (route) => {
        const url = new URL(route.request().url());
        if (url.host === local.host) return route.continue();
        stubbed.push(url.toString());
        const stub = EMPTY_BODY_BY_TYPE[route.request().resourceType()] ?? {
          contentType: 'text/plain',
          body: '',
        };
        await route.fulfill({ status: 200, ...stub });
      });
      await use({ stubbed });
    },
    { auto: true },
  ],

  consoleErrors: [
    async ({ page }, use) => {
      const collected: ConsoleErrors = { console: [], pageErrors: [], failedRequests: [] };
      page.on('console', (message) => {
        if (message.type() === 'error') collected.console.push(message.text());
      });
      page.on('pageerror', (error) => collected.pageErrors.push(error.message));
      page.on('requestfailed', (request) => {
        collected.failedRequests.push(`${request.url()} (${request.failure()?.errorText ?? 'unknown'})`);
      });
      page.on('response', (response) => {
        if (response.status() >= 400) {
          collected.failedRequests.push(`${response.url()} (HTTP ${response.status()})`);
        }
      });
      await use(collected);
    },
    { auto: true },
  ],
});

export { expect };
