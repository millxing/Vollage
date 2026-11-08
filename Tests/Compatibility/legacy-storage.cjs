'use strict';
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { pathToFileURL } = require('node:url');
const { spawn } = require('node:child_process');
const VIDEO = /\.(mp4|m4v|mov|mkv|wmv|flv|avi|webm)$/i;
const queues = new Map();
function serialized(key, task) {
  const previous = queues.get(key) || Promise.resolve();
  const next = previous.catch(() => {}).then(task);
  queues.set(key, next);
  return next.finally(() => { if (queues.get(key) === next) queues.delete(key); });
}
async function atomicJSON(file, value) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${randomUUID()}.tmp`;
  try { await fsp.writeFile(temp, JSON.stringify(value, null, 2) + '\n'); await fsp.rename(temp, file); }
  finally { await fsp.rm(temp, { force: true }); }
}
async function readRatings(file) {
  try {
    const data = JSON.parse(await fsp.readFile(file, 'utf8'));
    if (!data || Array.isArray(data) || typeof data !== 'object') throw Error('Expected a JSON object');
    return data;
  } catch (error) { if (error.code === 'ENOENT') return {}; throw Error(`Cannot read ratings: ${error.message}`); }
}
async function setRating(sourcePath, rating) {
  if (rating !== null && (!Number.isInteger(rating) || rating < 1 || rating > 10)) throw Error('Rating must be 1–10 or unrated');
  const sidecar = path.join(path.dirname(sourcePath), 'vollage-ratings.json');
  return serialized(sidecar, async () => {
    const ratings = await readRatings(sidecar);
    if (rating === null) delete ratings[path.basename(sourcePath)];
    else ratings[path.basename(sourcePath)] = rating;
    await atomicJSON(sidecar, ratings);
    return { sourcePath, rating, sidecar };
  });
}
function validateDocument(data) {
  if (!data || !Array.isArray(data.windows) || data.windows.length > 1000) throw Error('Invalid composition');
  const validateWindows = windows => {
    if (!Array.isArray(windows) || windows.length > 1000) throw Error('Invalid videos');
    const ids = new Set();
    for (const w of windows) {
      if (!w || !['x','y','width','height','speed','time'].every(k => Number.isFinite(w[k])) || w.width <= 0 || w.height <= 0 || w.width > 100000 || w.height > 100000 || w.speed < 0 || w.speed > 16 || w.time < 0) throw Error('Invalid video settings');
      for (const k of ['locked','pinned','paused','mirrored','muted']) if (w[k] !== undefined && typeof w[k] !== 'boolean') throw Error('Invalid video flags');
      if (w.volume !== undefined && (!Number.isFinite(w.volume) || w.volume < 0 || w.volume > 1)) throw Error('Invalid volume');
      if (w.blend !== undefined && !['normal','screen','multiply','difference','overlay'].includes(w.blend)) throw Error('Invalid blend');
      if (w.uid !== undefined && (typeof w.uid !== 'string' || !w.uid || ids.has(w.uid))) throw Error('Invalid video identity');
      if (w.uid) ids.add(w.uid);
    }
  };
  const validateMotion = motion => {
    if (motion == null) return;
    if (!Number.isFinite(motion.duration) || motion.duration <= 0 || motion.duration > 120 || !Array.isArray(motion.frames) || !motion.frames.length || motion.frames.length > 4000) throw Error('Invalid movement');
    let previous = -1;
    for (const f of motion.frames) {
      if (!Number.isFinite(f.t) || f.t < previous || f.t < 0 || f.t > motion.duration + .02 || !Array.isArray(f.positions) || f.positions.length > 1000) throw Error('Invalid movement frame');
      previous = f.t;
      for (const p of f.positions) if (!p || typeof p.uid !== 'string' || !['x','y','width','height'].every(k => Number.isFinite(p[k])) || p.width <= 0 || p.height <= 0) throw Error('Invalid movement position');
    }
  };
  validateWindows(data.windows); validateMotion(data.motion);
  if (data.scenes !== undefined && (!Array.isArray(data.scenes) || data.scenes.length !== 9)) throw Error('Invalid scenes');
  for (const s of data.scenes || []) if (s) { validateWindows(s.windows); validateMotion(s.motion); if (typeof s.name !== 'string' || s.name.length > 100) throw Error('Invalid scene name'); }
  if (data.canvas && (!['width','height'].every(k => Number.isInteger(data.canvas[k]) && data.canvas[k] >= 1 && data.canvas[k] <= 7680))) throw Error('Invalid canvas size');
  if (data.folder && (!Number.isInteger(data.folder.count) || data.folder.count < 1 || data.folder.count > 100 || !Number.isFinite(data.folder.seconds) || data.folder.seconds < 2 || data.folder.seconds > 3600)) throw Error('Invalid shuffle settings');
}
class MediaStore {
  constructor(root) { this.root = root; this.assets = new Map(); this.paths = new Map(); this.conversions = new Map(); }
  async register(filePath, options = {}) {
    filePath = path.resolve(filePath);
    if (!VIDEO.test(filePath)) throw Error('Choose a supported video file');
    const stat = await fsp.stat(filePath);
    if (!stat.isFile()) throw Error('Not a video file');
    const key = `${filePath}:${stat.size}:${stat.mtimeMs}`;
    if (this.paths.has(key)) return this.describe(this.assets.get(this.paths.get(key)));
    const asset = { id: randomUUID(), path: filePath, sourcePath: options.sourcePath || filePath, name: options.name || path.basename(filePath), size: stat.size, lastModified: stat.mtimeMs, playbackPath: filePath, embedded: !!options.embedded };
    this.assets.set(asset.id, asset); this.paths.set(key, asset.id);
    return this.describe(asset);
  }
  get(id) { const a = this.assets.get(id); if (!a) throw Error('Video is no longer available'); return a; }
  async originalPath(asset) {
    try { if (VIDEO.test(asset.sourcePath) && (await fsp.stat(asset.sourcePath)).isFile()) return asset.sourcePath; } catch {}
    return asset.path;
  }
  async describe(asset) {
    const sourcePath = await this.originalPath(asset);
    let rating = null, ratingError = null;
    try { const v = (await readRatings(path.join(path.dirname(sourcePath), 'vollage-ratings.json')))[path.basename(sourcePath)]; if (Number.isInteger(v) && v >= 1 && v <= 10) rating = v; }
    catch (e) { ratingError = e.message; }
    return { nativeId: asset.id, name: asset.name, size: asset.size, lastModified: asset.lastModified, url: `vollage://app/media/${asset.id}${asset.playbackPath!==asset.path?'?converted=1':''}`, sourcePath, rating, ratingError, embedded: asset.embedded, converted: asset.playbackPath !== asset.path };
  }
  async listFolder(folder) {
    const found = [];
    const walk = async dir => {
      for (const e of await fsp.readdir(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory() && !e.name.startsWith('.')) await walk(p);
        else if (e.isFile() && VIDEO.test(e.name)) found.push(p);
      }
    };
    await walk(folder);
    return Promise.all(found.map(p => this.register(p)));
  }
  async rate(id, rating) { const a = this.get(id); return setRating(await this.originalPath(a), rating); }
  async convert(id) {
    const asset = this.get(id);
    if (this.conversions.has(asset.path)) return this.conversions.get(asset.path);
    const job = this.convertAsset(asset).finally(() => this.conversions.delete(asset.path));
    this.conversions.set(asset.path, job); return job;
  }
  async convertAsset(asset) {
    const digest = createHash('sha256').update(`${asset.path}:${asset.size}:${asset.lastModified}`).digest('hex');
    const output = path.join(this.root, 'converted', `${digest}.mp4`);
    await fsp.mkdir(path.dirname(output), { recursive: true });
    try { if ((await fsp.stat(output)).size > 0) { asset.playbackPath = output; return this.describe(asset); } } catch {}
    const ffmpeg = ['/opt/homebrew/bin/ffmpeg','/usr/local/bin/ffmpeg'].find(p => fs.existsSync(p));
    if (!ffmpeg) throw Error('FFmpeg is required to convert this video. Install it with Homebrew, then retry.');
    const temp = `${output}.${randomUUID()}.mp4`;
    try {
      await new Promise((resolve, reject) => {
        const child = spawn(ffmpeg, ['-nostdin','-v','error','-i',asset.path,'-map','0:v:0','-map','0:a:0?','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2','-c:a','aac','-movflags','+faststart','-y',temp], { stdio: ['ignore','ignore','pipe'] });
        let error = '';
        child.stderr.on('data', b => { error = (error + b.toString()).slice(-2000); });
        child.on('error', reject); child.on('exit', code => code === 0 ? resolve() : reject(Error(`Conversion failed: ${error || code}`)));
      });
      await fsp.rename(temp, output); asset.playbackPath = output; return this.describe(asset);
    } finally { await fsp.rm(temp, { force: true }); }
  }
  encode(document) {
    validateDocument(document);
    const ids = [], assets = [];
    const encodeWindows = windows => windows.map(({ file, ...w }) => {
      const id = file?.nativeId; const a = this.get(id);
      let index = ids.indexOf(id);
      if (index < 0) { index = ids.length; ids.push(id); assets.push({ name: a.name, size: a.size, sourcePath: a.sourcePath, lastModified: a.lastModified }); }
      return { ...w, asset: index };
    });
    const data = { ...document, version: 5, windows: encodeWindows(document.windows), scenes: (document.scenes || Array(9).fill(null)).map(s => s ? { ...s, windows: encodeWindows(s.windows) } : null), assets };
    return { data, ids };
  }
  async saveProject(file, document) {
    const { data, ids } = this.encode(document);
    return serialized(file, async () => {
      const manifest = Buffer.from(JSON.stringify(data));
      const header = Buffer.alloc(12); header.write('VOLLAGE1'); header.writeUInt32LE(manifest.length, 8);
      const temp = `${file}.${randomUUID()}.tmp`;
      const out = await fsp.open(temp, 'wx');
      try {
        await out.writeFile(header); await out.writeFile(manifest);
        for (const id of ids) {
          const a = this.get(id);
          if ((await fsp.stat(a.path)).size !== a.size) throw Error(`Source changed: ${a.name}. Add it again before saving.`);
          for await (const chunk of fs.createReadStream(a.path)) await out.writeFile(chunk);
        }
        await out.sync(); await out.close(); await fsp.rename(temp, file);
      } catch (e) { await out.close().catch(() => {}); throw e; }
      finally { await fsp.rm(temp, { force: true }); }
      return file;
    });
  }
  async loadProject(file) {
    const stat = await fsp.stat(file); const input = await fsp.open(file, 'r');
    let data, offset;
    try {
      const header = Buffer.alloc(12); const h = await input.read(header, 0, 12, 0);
      if (h.bytesRead !== 12 || header.toString('utf8',0,8) !== 'VOLLAGE1') throw Error('Not a Vollage project');
      const length = header.readUInt32LE(8);
      if (length > 64*1024*1024 || length+12 > stat.size) throw Error('Invalid project header');
      const manifest = Buffer.alloc(length); await input.read(manifest, 0, length, 12); data = JSON.parse(manifest.toString()); offset = 12+length;
    } finally { await input.close(); }
    if (![1,4,5].includes(data.version) || !Array.isArray(data.assets) || data.assets.length > 10000) throw Error('Unsupported project version');
    validateDocument(data);
    for (const a of data.assets) {
      if (typeof a.name !== 'string' || !VIDEO.test(a.name) || !Number.isSafeInteger(a.size) || a.size < 0 || offset+a.size > stat.size) throw Error('Invalid embedded video');
      offset += a.size;
    }
    if (offset !== stat.size) throw Error('Invalid project length');
    const hash = createHash('sha256').update(`${path.resolve(file)}:${stat.size}:${stat.mtimeMs}`).digest('hex');
    const folder = path.join(this.root, 'embedded', hash); await fsp.mkdir(folder, { recursive: true });
    offset = 12 + Buffer.byteLength(JSON.stringify(data)); // reset from actual header, not reserialized whitespace
    const h = await fsp.open(file,'r'); const b=Buffer.alloc(12); await h.read(b,0,12,0); await h.close(); offset=12+b.readUInt32LE(8);
    const files = [];
    for (let i=0;i<data.assets.length;i++) {
      const a=data.assets[i], output=path.join(folder, `${i}-${path.basename(a.name)}`);
      let exists=false; try { exists=(await fsp.stat(output)).size===a.size; } catch {}
      if (!exists) {
        const temp=`${output}.${randomUUID()}.tmp`, out=await fsp.open(temp,'w');
        try { if(a.size) for await(const chunk of fs.createReadStream(file,{start:offset,end:offset+a.size-1})) await out.writeFile(chunk); await out.close(); await fsp.rename(temp,output); }
        catch(e){await out.close().catch(()=>{});await fsp.rm(temp,{force:true});throw e;}
      }
      let sourcePath=output;
      if(typeof a.sourcePath==='string' && VIDEO.test(a.sourcePath)) { try { const s=await fsp.stat(a.sourcePath); if(s.isFile()&&s.size===a.size)sourcePath=a.sourcePath; } catch {} }
      files.push(await this.register(output,{name:a.name,sourcePath,embedded:true})); offset+=a.size;
    }
    const decode = windows => windows.map(w => {
      if (!Number.isInteger(w.asset) || !files[w.asset]) throw Error('Missing embedded video');
      return { ...w, uid: w.uid || randomUUID(), pinned: w.pinned ?? (data.version<5 && !!w.locked), file: files[w.asset] };
    });
    return {...data, windows:decode(data.windows), scenes:(data.scenes||Array(9).fill(null)).map(s=>s?{...s,windows:decode(s.windows)}:null)};
  }
  async recoverDocument(document) {
    validateDocument(document);
    const cache = new Map();
    const decode = async windows => Promise.all(windows.map(async w => {
      const source=w.file;
      if (!cache.has(source.path)) cache.set(source.path,this.register(source.path,{name:source.name,sourcePath:source.sourcePath,embedded:source.embedded}));
      return {...w,file:await cache.get(source.path)};
    }));
    return {...document,windows:await decode(document.windows),scenes:await Promise.all(document.scenes.map(async s=>s?{...s,windows:await decode(s.windows)}:null))};
  }
  recoveryDocument(document) {
    validateDocument(document);
    const windows = items => items.map(w=>{const a=this.get(w.file.nativeId);return {...w,file:{path:a.path,sourcePath:a.sourcePath,name:a.name,embedded:a.embedded}};});
    return {...document,windows:windows(document.windows),scenes:document.scenes.map(s=>s?{...s,windows:windows(s.windows)}:null)};
  }
}
module.exports = { MediaStore, setRating, readRatings, atomicJSON, validateDocument, VIDEO, serialized };
