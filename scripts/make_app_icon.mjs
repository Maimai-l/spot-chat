// Draws the app icon, Pinhole: an ultramarine disc with a hole, on a paper tile, and writes the PNGs of
// App/Assets.xcassets/AppIcon.appiconset. Run with `node scripts/make_app_icon.mjs`.
//
// Geometry is on Apple's 1024 grid, with the tile 824 wide. The disc is 824 × 0.618 across, the hole is a fifth
// of its radius, and its center lies R/φ from the disc's along 45°. The disc sits 6 up so it looks centered.
// Small sizes are corrected by eye: at 64 and under the shadow goes, at 32 and under the disc and hole grow.
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Playwright is loaded with require so a globally installed copy is found too.
const { chromium } = createRequire(import.meta.url)("playwright");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const iconSet = join(root, "App/Assets.xcassets/AppIcon.appiconset");

const ink = "#2A3AA0";

// The tile's outline, Apple's macOS icon shape traced on the 1024 grid.
const tile =
  "M924 512L924 630L923 667L923 694L921 717L920 735L918 752L916 767L914 780L911 793L908 804L905 814L901 824L897 833L892 842L888 850L882 857L877 864L871 871L864 877L857 882L850 888L842 892L833 897L824 901L814 905L804 908L793 911L780 914L767 916L752 918L735 920L717 921L694 923L667 923L630 924L512 924L394 924L357 923L330 923L307 921L289 920L272 918L257 916L244 914L231 911L220 908L210 905L200 901L191 897L182 892L174 888L167 882L160 877L153 871L147 864L142 857L136 850L132 842L127 833L123 824L119 814L116 804L113 793L110 780L108 767L106 752L104 735L103 717L101 694L101 667L100 630L100 512L100 394L101 357L101 330L103 307L104 289L106 272L108 257L110 244L113 231L116 220L119 210L123 200L127 191L132 182L136 174L142 167L147 160L153 153L160 147L167 142L174 136L182 132L191 127L200 123L210 119L220 116L231 113L244 110L257 108L272 106L289 104L307 103L330 101L357 101L394 100L512 100L630 100L667 101L694 101L717 103L735 104L752 106L767 108L780 110L793 113L804 116L814 119L824 123L833 127L842 132L850 136L857 142L864 147L871 153L877 160L882 167L888 174L892 182L897 191L901 200L905 210L908 220L911 231L914 244L916 257L918 272L920 289L921 307L923 330L923 357L924 394Z";

// One look per size range, as the design draws them.
const looks = {
  large: { disc: [512, 506, 255], hole: [623.4, 394.6, 51], rim: [0.07, 2], shadow: 0.32, gradient: true },
  dock: { disc: [512, 506, 255], hole: [623.4, 394.6, 51], rim: [0.08, 5], shadow: 0.3, gradient: true },
  small: { disc: [512, 506, 255], hole: [623.4, 394.6, 51], rim: [0.1, 10], shadow: 0, gradient: false },
  tiny: { disc: [512, 512, 270], hole: [625.1, 398.9, 64], rim: [0.12, 18], shadow: 0, gradient: false },
  smallest: { disc: [512, 512, 280], hole: [611, 413, 78], rim: [0.14, 30], shadow: 0, gradient: false },
};

const circle = ([x, y, r]) => `M${x} ${y - r}a${r} ${r} 0 1 0 0 ${2 * r}a${r} ${r} 0 1 0 0 ${-2 * r}Z`;

function svg(look) {
  const mark = circle(look.disc) + circle(look.hole);
  const [rimOpacity, rimWidth] = look.rim;
  const fill = look.gradient ? "url(#paper)" : "#F5F2EA";
  const shadow = look.shadow
    ? `<path d="${mark}" fill-rule="evenodd" fill="#1B2150" fill-opacity="${look.shadow}" transform="translate(0 12)" filter="url(#blur)"/>`
    : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="100%" height="100%">
<defs>
<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FBF9F4"/><stop offset="1" stop-color="#ECE8DE"/></linearGradient>
<filter id="blur" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur stdDeviation="9"/></filter>
</defs>
<path d="${tile}" fill="${fill}" stroke="#000" stroke-opacity="${rimOpacity}" stroke-width="${rimWidth}"/>
${shadow}
<path d="${mark}" fill-rule="evenodd" fill="${ink}"/>
</svg>`;
}

// Each file in the icon set, its size in pixels, and the look drawn at that size.
const files = [
  ["icon_16x16.png", 16, "smallest"],
  ["icon_16x16@2x.png", 32, "tiny"],
  ["icon_32x32.png", 32, "tiny"],
  ["icon_32x32@2x.png", 64, "small"],
  ["icon_128x128.png", 128, "dock"],
  ["icon_128x128@2x.png", 256, "large"],
  ["icon_256x256.png", 256, "large"],
  ["icon_256x256@2x.png", 512, "large"],
  ["icon_512x512.png", 512, "large"],
  ["icon_512x512@2x.png", 1024, "large"],
];

const browser = await chromium.launch();
const page = await browser.newPage();
for (const [name, size, look] of files) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(
    `<html><body style="margin:0;background:transparent"><div style="width:${size}px;height:${size}px">${svg(looks[look])}</div></body></html>`
  );
  const png = await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  writeFileSync(join(iconSet, name), png);
  console.log(`${name} ${size}px ${look}`);
}
await browser.close();
