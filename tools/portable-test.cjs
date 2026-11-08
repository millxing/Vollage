const { MediaStore } = require('../Tests/Compatibility/legacy-storage.cjs');
const path = require('node:path');
const fs = require('node:fs/promises');
(async () => {
  const root = process.argv[2];
  const store = new MediaStore('/tmp/vollage-native-electron-check');
  const project = await store.loadProject(path.join(root, 'native-export.vollage'));
  if (project.windows.length !== 2 || project.scenes[0]?.name !== 'First Scene') throw Error('Native project failed desktop compatibility');
  await store.saveProject(path.join(root, 'electron-roundtrip.vollage'), project);
  const buffer = await fs.readFile(path.join(root, 'native-export.vollage'));
  const manifest = JSON.parse(buffer.subarray(12, 12 + buffer.readUInt32LE(8)));
  const unique = new Set([...manifest.windows, ...manifest.scenes.filter(Boolean).flatMap(s => s.windows)].map(w => w.asset));
  if (unique.size !== manifest.assets.length) throw Error('Embedded media not deduplicated');
  const media = buffer.subarray(12 + buffer.readUInt32LE(8));
  for (const version of [1, 4]) {
    const legacy = {...manifest, version};
    if (version === 1) { delete legacy.scenes; delete legacy.folder; delete legacy.motion; }
    const json = Buffer.from(JSON.stringify(legacy)); const header = Buffer.alloc(12); header.write('VOLLAGE1'); header.writeUInt32LE(json.length,8);
    await fs.writeFile(path.join(root, `browser-${version}.vollage`), Buffer.concat([header,json,media]));
  }
  console.log('PASS native portable project opens and saves with Electron storage; media deduplicated across scenes');
})().catch(e => { console.error(e); process.exit(1); });
