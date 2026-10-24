// 识别模型下载器测试（不开窗口、不联网）：本机起一个支持 Range 的 HTTP 服务，故意断线 / 报错 / 不认 Range，
// 用「AI Meeting --download-test」跑 ModelDownloader，检查断点续传、换源、校验。
// 用法：node app/test-download.mjs <AI Meeting 可执行文件>
import { spawn } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import assert from 'node:assert/strict'

const BIN = process.argv[2]
if (!BIN) { console.error('用法：node app/test-download.mjs <AI Meeting 可执行文件>'); process.exit(2) }
const SIZE = 3 * 1024 * 1024 + 12345
const DATA = crypto.randomBytes(SIZE)
const SHA = crypto.createHash('sha256').update(DATA).digest('hex')
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'aim-dl-'))

let log = []
const dropped = new Set()
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x')
  const [, kind] = u.pathname.split('/')
  const range = req.headers.range || ''
  log.push(`${kind} ${range}`)
  const slow = Number(u.searchParams.get('slow') || 0)   // 每 20ms 发多少 KB（0 = 全速）
  if (kind === 'fail') { res.writeHead(500); res.end('boom'); return }
  if (kind === 'redirect') { res.writeHead(302, { location: '/ok/model.bin' + u.search }); res.end(); return }
  let body = DATA
  if (kind === 'wrongsize') body = DATA.subarray(0, 2 * 1024 * 1024)
  let start = 0
  const m = /bytes=(\d+)-/.exec(range)
  if (m && kind !== 'norange') {
    start = Number(m[1])
    if (start >= body.length) { res.writeHead(416, { 'content-range': `bytes */${body.length}` }); res.end(); return }
    res.writeHead(206, { 'content-length': body.length - start, 'content-range': `bytes ${start}-${body.length - 1}/${body.length}`, 'accept-ranges': 'bytes' })
  } else {
    res.writeHead(200, { 'content-length': body.length, 'accept-ranges': kind === 'norange' ? 'none' : 'bytes' })
  }
  let chunk = body.subarray(start)
  if (kind === 'drop' && !dropped.has(u.search)) {   // 第一次：发 1MB 后掐断连接
    dropped.add(u.search)
    res.write(chunk.subarray(0, 1024 * 1024), () => setTimeout(() => req.socket.destroy(), 50))
    return
  }
  if (!slow) { res.end(chunk); return }
  let o = 0
  const iv = setInterval(() => {
    if (res.destroyed) return clearInterval(iv)
    const n = slow * 1024
    res.write(chunk.subarray(o, o + n)); o += n
    if (o >= chunk.length) { clearInterval(iv); res.end() }
  }, 20)
  res.on('close', () => clearInterval(iv))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const base = `http://127.0.0.1:${server.address().port}`

function run(urls, { sha = SHA, env = {}, killAfterMs = 0 } = {}) {
  const dest = path.join(TMP, 'model.bin')
  const args = ['--download-test', ...urls.flatMap((u) => ['--url', base + u]), '--dest', dest, '--size', String(SIZE), '--sha', sha]
  return new Promise((resolve) => {
    const p = spawn(BIN, args, { env: { ...process.env, AIM_DL_RETRY_BASE: '0.1', AIM_DL_TIMEOUT: '5', ...env } })
    let out = ''
    p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (out += d))
    if (killAfterMs) setTimeout(() => p.kill('SIGKILL'), killAfterMs)
    p.on('exit', (code, sig) => resolve({ code, sig, out, dest, part: dest + '.part' }))
  })
}
const sha256 = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')
const size = (f) => (fs.existsSync(f) ? fs.statSync(f).size : -1)
const reset = () => { for (const f of fs.readdirSync(TMP)) fs.rmSync(path.join(TMP, f)); log = [] }
let n = 0
async function t(name, fn) {
  reset()
  try { await fn(); console.log(`ok   ${++n} ${name}`) } catch (e) { console.log(`FAIL ${++n} ${name}\n${e.stack}\n--- 请求记录 ---\n${log.join('\n')}`); process.exitCode = 1 }
}

await t('全新下载（经 302 跳转），校验通过，.part 改名成目标文件', async () => {
  const r = await run(['/redirect/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.match(r.out, /RESULT ok/)
  assert.equal(sha256(r.dest), SHA)
  assert.equal(size(r.part), -1)
  assert.match(r.out, /progress \d+ \d+/)
})

await t('第一个源 500 → 换镜像下完', async () => {
  const r = await run(['/fail/model.bin', '/ok/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
  assert.deepEqual(log.map((l) => l.split(' ')[0]), ['fail', 'ok'])
})

await t('下到一半断线 → 自动带 Range 从断点接着下', async () => {
  const r = await run(['/drop/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
  assert.equal(log[0], 'drop ')
  assert.equal(log[1], `drop bytes=${1024 * 1024}-`)
  assert.match(r.out, /retrying/)
})

await t('下载中途 App 被强退 → 重开后从 .part 接着下（经跳转也带 Range）', async () => {
  const r1 = await run(['/ok/model.bin?slow=64'], { killAfterMs: 800 })
  assert.equal(r1.sig, 'SIGKILL')
  const partial = size(r1.part)
  assert.ok(partial > 0 && partial < SIZE, `partial=${partial}`)
  log = []
  const r2 = await run(['/redirect/model.bin'])
  assert.equal(r2.code, 0, r2.out)
  assert.equal(sha256(r2.dest), SHA)
  assert.match(r2.out, new RegExp(`connecting ${partial} `))
  assert.deepEqual(log, [`redirect bytes=${partial}-`, `ok bytes=${partial}-`])
})

await t('服务器不认 Range（回 200 整个文件）→ 丢掉 .part 从头下，结果正确', async () => {
  fs.writeFileSync(path.join(TMP, 'model.bin.part'), DATA.subarray(0, 1024 * 1024))
  const r = await run(['/norange/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
})

await t('.part 前半段是坏数据 → 校验不过自动删掉重下', async () => {
  fs.writeFileSync(path.join(TMP, 'model.bin.part'), crypto.randomBytes(1024 * 1024))
  const r = await run(['/ok/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
  assert.match(r.out, /checksum mismatch/)
  assert.deepEqual(log, [`ok bytes=${1024 * 1024}-`, 'ok '])
})

await t('.part 已经完整（上次退出时没来得及校验）→ 不再联网，直接校验完成', async () => {
  fs.writeFileSync(path.join(TMP, 'model.bin.part'), DATA)
  const r = await run(['/ok/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
  assert.equal(log.length, 0)
})

await t('源文件大小不对 → 不收，换下一个源', async () => {
  const r = await run(['/wrongsize/model.bin', '/ok/model.bin'])
  assert.equal(r.code, 0, r.out)
  assert.equal(sha256(r.dest), SHA)
})

await t('所有源都不通 → 重试几次后报失败，已下载的 .part 保留', async () => {
  fs.writeFileSync(path.join(TMP, 'model.bin.part'), DATA.subarray(0, 500000))
  const r = await run(['/fail/model.bin'], { env: { AIM_DL_MAX_FAILURES: '3' } })
  assert.equal(r.code, 1, r.out)
  assert.match(r.out, /RESULT fail HTTP 500/)
  assert.equal(size(path.join(TMP, 'model.bin.part')), 500000)
  assert.equal(log.length, 3)
})

await t('连不上（端口没人听）→ 报失败不卡死', async () => {
  const dead = http.createServer(); await new Promise((r) => dead.listen(0, '127.0.0.1', r)); const port = dead.address().port; dead.close()
  const dest = path.join(TMP, 'model.bin')
  const r = await new Promise((resolve) => {
    const p = spawn(BIN, ['--download-test', '--url', `http://127.0.0.1:${port}/x`, '--dest', dest, '--size', String(SIZE)], { env: { ...process.env, AIM_DL_RETRY_BASE: '0.1', AIM_DL_MAX_FAILURES: '2' } })
    let out = ''; p.stdout.on('data', (d) => (out += d)); p.on('exit', (code) => resolve({ code, out }))
  })
  assert.equal(r.code, 1, r.out)
  assert.match(r.out, /RESULT fail/)
})

server.close()
fs.rmSync(TMP, { recursive: true, force: true })
console.log(process.exitCode ? '下载器测试有失败' : `下载器测试全部通过（${n} 项）`)
