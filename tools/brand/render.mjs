// Generates the Lightsphere brand SVGs (outlined Inter Bold, no font needed) and PNG previews.
// Usage: npm install && npm run render
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import opentype from "opentype.js";
import { Resvg } from "@resvg/resvg-js";

const OUT = process.argv[2];
mkdirSync(OUT, { recursive: true });
const ORANGE = "#FF3C00";
const INK = "#141414";
const WHITE = "#FFFFFF";

const font = (w) => {
  const b = readFileSync(`node_modules/@fontsource/inter/files/inter-latin-${w}-normal.woff`);
  return opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
};
const bold = font(700);

/**
 * The glyph on a 128 grid: a solid sphere cut by a tilted equator, floating above the ledger line it settles
 * to. The cut is a mask, so the glyph works on any background.
 */
let maskSeq = 0;
function glyph(color) {
  const id = `ls-cut-${maskSeq++}`;
  return `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="128" height="128"><rect width="128" height="128" fill="#fff"/><path d="M28 54A36 12.5 0 0 0 100 54" transform="rotate(-20 64 54)" fill="none" stroke="#000" stroke-width="7"/></mask></defs>
  <circle cx="64" cy="54" r="31" fill="${color}" mask="url(#${id})"/>
  <path d="M34 104H94" stroke="${color}" stroke-width="8" stroke-linecap="round"/>`;
}

const svg = (w, h, body, title = "Lightsphere") =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="${title}">\n  <title>${title}</title>\n  ${body}\n</svg>\n`;

const mark = svg(128, 128, `<rect width="128" height="128" rx="30" fill="${ORANGE}"/>\n  ${glyph(WHITE)}`);

// Wordmark: Inter Bold, -2.5% tracking, outlined.
function wordPath(text, size, color, x = 0, baseline = size) {
  const tracking = -0.025 * size;
  let cursor = x;
  const parts = [];
  const glyphs = bold.stringToGlyphs(text);
  for (let i = 0; i < glyphs.length; i++) {
    const g = glyphs[i];
    parts.push(g.getPath(cursor, baseline, size).toPathData(2));
    let adv = (g.advanceWidth / bold.unitsPerEm) * size;
    if (i < glyphs.length - 1) adv += (bold.getKerningValue(g, glyphs[i + 1]) / bold.unitsPerEm) * size;
    cursor += adv + tracking;
  }
  return { d: parts.join(""), width: cursor - tracking - x };
}

const WORD_SIZE = 64;
const asc = (bold.ascender / bold.unitsPerEm) * WORD_SIZE; // ~ 62
const capH = 0.727 * WORD_SIZE;
function wordmark(color) {
  const { d, width } = wordPath("Lightsphere", WORD_SIZE, color, 0, asc);
  const h = Math.ceil(asc + 0.25 * WORD_SIZE); // room for the descender of p/g
  return { body: `<path fill="${color}" d="${d}"/>`, width: Math.ceil(width), height: h };
}

function lockup(textColor) {
  const markSize = 96;
  const gap = 26;
  const w = wordmark(textColor);
  const height = markSize;
  // Center the cap height of the word on the mark.
  const ty = (markSize - capH) / 2 - (asc - capH);
  const width = markSize + gap + w.width;
  const body = `<g transform="scale(${markSize / 128})"><rect width="128" height="128" rx="30" fill="${ORANGE}"/>${glyph(WHITE)}</g>
  <g transform="translate(${markSize + gap} ${ty.toFixed(2)})">${w.body}</g>`;
  return svg(width, height, body);
}

const files = {
  "lightsphere-mark.svg": mark,
  "lightsphere-glyph-orange.svg": svg(128, 128, glyph(ORANGE)),
  "lightsphere-glyph-white.svg": svg(128, 128, glyph(WHITE)),
  "lightsphere-glyph-ink.svg": svg(128, 128, glyph(INK)),
  "lightsphere-wordmark-ink.svg": (() => { const w = wordmark(INK); return svg(w.width, w.height, w.body); })(),
  "lightsphere-wordmark-white.svg": (() => { const w = wordmark(WHITE); return svg(w.width, w.height, w.body); })(),
  "lightsphere-lockup-ink.svg": lockup(INK),
  "lightsphere-lockup-white.svg": lockup(WHITE),
};
for (const [name, body] of Object.entries(files)) writeFileSync(`${OUT}/${name}`, body);

const png = (svgText, width, background) =>
  new Resvg(svgText, { fitTo: { mode: "width", value: width }, background }).render().asPng();
const uri = (s) => `data:image/svg+xml;base64,${Buffer.from(s).toString("base64")}`;

// Review sheet: mark at sizes, lockups on light and dark.
const sizes = [16, 32, 48, 96, 160];
let x = 40;
const marks = sizes.map((s) => { const el = `<image href="${uri(mark)}" x="${x}" y="${200 - s}" width="${s}" height="${s}"/>`; x += s + 40; return el; }).join("");
const lockInk = files["lightsphere-lockup-ink.svg"];
const lockWhite = files["lightsphere-lockup-white.svg"];
const lw = Number(/width="(\d+(\.\d+)?)"/.exec(lockInk)[1]);
const sheet = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760">
  <rect width="1200" height="380" fill="#FFFFFF"/><rect y="380" width="1200" height="380" fill="#0D1117"/>
  ${marks}
  <image href="${uri(lockInk)}" x="40" y="250" width="${lw * 0.9}" height="${96 * 0.9}"/>
  <image href="${uri(lockWhite)}" x="40" y="430" width="${lw * 0.9}" height="${96 * 0.9}"/>
  <image href="${uri(files["lightsphere-glyph-white.svg"])}" x="40" y="560" width="160" height="160"/>
  <image href="${uri(files["lightsphere-glyph-orange.svg"])}" x="240" y="560" width="160" height="160"/>
  <rect x="440" y="560" width="160" height="160" fill="${ORANGE}" rx="0"/>
  <image href="${uri(files["lightsphere-glyph-ink.svg"])}" x="640" y="560" width="160" height="160"/>
  <rect x="640" y="560" width="160" height="160" fill="none"/>
</svg>`;
writeFileSync(`${OUT}/preview.png`, png(sheet, 1200, "#ffffff"));

// GitHub social preview, 1280x640.
const social = `<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="640" viewBox="0 0 1280 640">
  <defs><radialGradient id="g" cx="0.78" cy="0.25" r="0.9"><stop offset="0" stop-color="#2A1208"/><stop offset="0.55" stop-color="#0D0D0F"/></radialGradient></defs>
  <rect width="1280" height="640" fill="url(#g)"/>
  <image href="${uri(files["lightsphere-glyph-orange.svg"])}" x="790" y="90" width="460" height="460" opacity="0.16"/>
  <image href="${uri(lockWhite)}" x="96" y="200" width="${lw * 1.25}" height="${96 * 1.25}"/>
  <path fill="#B8B8C0" d="${wordPath("Off-ledger execution, settled on Hiero", 34, "#B8B8C0", 96, 420).d}"/>
  <path fill="${ORANGE}" d="${wordPath("ColdAI", 26, ORANGE, 96, 540).d}"/>
</svg>`;
writeFileSync(`${OUT}/social-preview.png`, png(social, 1280));
writeFileSync(`${OUT}/mark-512.png`, png(mark, 512));
console.log("wrote", Object.keys(files).length, "svgs + previews to", OUT);
