// Points the primary download buttons at the build for this Mac's chip.
// Without JavaScript, or when the chip cannot be identified, they keep /download,
// which serves the universal build that runs on every Mac.
(() => {
  const LABELS = {'apple-silicon': 'Download for Apple Silicon', intel: 'Download for Intel Mac'};

  function fromGraphics() {
    try {
      const gl = document.createElement('canvas').getContext('webgl');
      if (!gl) return null;
      const info = gl.getExtension('WEBGL_debug_renderer_info');
      const renderer = info ? String(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) : '';
      // Safari reports a generic "Apple GPU"; of Mac GPUs only Apple Silicon supports ASTC textures.
      const astc = Boolean(gl.getExtension('WEBGL_compressed_texture_astc'));
      gl.getExtension('WEBGL_lose_context')?.loseContext();
      if (/Apple M\d/i.test(renderer)) return 'apple-silicon';
      if (/Intel|AMD|Radeon|NVIDIA/i.test(renderer)) return 'intel';
      if (/Apple GPU/i.test(renderer) && astc) return 'apple-silicon';
    } catch {
      // Detection is best effort; the universal default still works.
    }
    return null;
  }

  async function detect() {
    const uaData = navigator.userAgentData;
    if (uaData) {
      if (uaData.platform !== 'macOS') return null;
      try {
        const {architecture} = await uaData.getHighEntropyValues(['architecture']);
        if (architecture === 'arm') return 'apple-silicon';
        if (architecture === 'x86') return 'intel';
      } catch {
        // Fall through to the graphics probe.
      }
      return fromGraphics();
    }
    // iPads also claim "Macintosh" but have touch screens.
    if (!/Macintosh/.test(navigator.userAgent) || navigator.maxTouchPoints > 1) return null;
    return fromGraphics();
  }

  function apply(arch) {
    if (!LABELS[arch]) return;
    for (const link of document.querySelectorAll('a[data-download]')) {
      link.setAttribute('href', `/download/${arch}`);
      const label = link.querySelector('[data-download-label]');
      if (label) label.textContent = LABELS[arch];
    }
    document.documentElement.dataset.macChip = arch;
  }

  detect().then(apply, () => {});
})();
