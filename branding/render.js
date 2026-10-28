const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  for (const [svg, png, size] of [
    ['icon_full.svg','icon.png',1024], ['icon_foreground.svg','icon_foreground.png',1024],
    ['icon_background.svg','icon_background.png',1024], ['logo_mark.svg','logo_mark.png',512],
  ]) {
    await p.setViewportSize({ width: size, height: size });
    const s = fs.readFileSync(svg,'utf8').replace('<svg ', `<svg width="${size}" height="${size}" `);
    await p.setContent(`<html><body style="margin:0;background:transparent">${s}</body></html>`);
    await p.screenshot({ path: png, omitBackground: true, clip: {x:0,y:0,width:size,height:size} });
  }
  await b.close();
})();
