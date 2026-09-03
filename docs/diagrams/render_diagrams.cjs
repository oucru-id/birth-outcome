// Usage: NODE_PATH=<directory containing dependencies> node render_diagrams.cjs
// Requires @viz-js/viz and sharp. No data or BigQuery connection is used.
const fs = require('node:fs/promises');
const path = require('node:path');
const { instance } = require('@viz-js/viz');
const sharp = require('sharp');

(async () => {
  const viz = await instance();
  for (const name of ['pregnancy_sources', 'sigizi_sources', 'epus_sources', 'sigizi_deletion_exclusion', 'other_sources', 'simrs_facility_sources', 'kobo_sources', 'core_reporting', 'raw_sources_to_reporting']) {
    const source = await fs.readFile(path.join(__dirname, name + '.dot'), 'utf8');
    const svg = viz.renderString(source, {format: 'svg', engine: 'dot'});
    await fs.writeFile(path.join(__dirname, name + '.svg'), svg);
    const png = await sharp(Buffer.from(svg), {density: 120}).png().toBuffer();
    if (png.subarray(-8).toString('hex') !== '49454e44ae426082') {
      throw new Error(`Incomplete PNG output: ${name}`);
    }
    await fs.writeFile(path.join(__dirname, name + '.png'), png);
    const meta = await sharp(path.join(__dirname, name + '.png')).metadata();
    console.log(`${name}: ${meta.width} x ${meta.height}`);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
