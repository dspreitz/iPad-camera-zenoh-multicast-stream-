// Öffnet den Web-Viewer headless, wartet, liest window.zvStats und macht einen Screenshot.
// Aufruf: node headless.js [url] [sekunden] [screenshot.png]
const puppeteer = require('puppeteer-core');
const url = process.argv[2] || 'http://localhost:8080/';
const secs = Number(process.argv[3] || 20);
const shot = process.argv[4] || '/out/viewer.png';
(async () => {
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME || '/usr/bin/chromium',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required'],
  });
  const page = await browser.newPage();
  page.on('console', (m) => console.log('[page]', m.type(), m.text()));
  await page.setViewport({ width: 700, height: 480 });
  await page.goto(url, { waitUntil: 'load' });
  const support = await page.evaluate(async () => {
    if (!('VideoDecoder' in window)) return { webcodecs: false };
    const r = await VideoDecoder.isConfigSupported({ codec: 'avc1.42c01e' });
    return { webcodecs: true, h264: r.supported };
  });
  console.log('support', JSON.stringify(support));
  const samples = [];
  for (let t = 0; t < secs; t += 5) {
    await new Promise((r) => setTimeout(r, 5000));
    const s = await page.evaluate(() => ({ ...window.zvStats }));
    samples.push(s);
    console.log(`t=${t + 5}s`, JSON.stringify(s));
  }
  await page.screenshot({ path: shot });
  const last = samples[samples.length - 1];
  const ok = last.decoded > 0 && last.fps > 5;
  console.log(ok ? 'RESULT OK' : 'RESULT FAIL', `decoded=${last.decoded} fps=${last.fps} errors=${last.decodeErrors}`);
  await browser.close();
  process.exit(ok ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(2); });
