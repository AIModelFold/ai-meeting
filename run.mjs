#!/usr/bin/env node
// AI Meeting（原「会议助手」）引擎：电脑声音（+ 麦克风）→ 实时文字稿（Whisper 本机识别）→ 实时翻译（Mac 离线翻译）→ 问题回答
//
//   capture（系统声音 16kHz PCM → stdout；--mic 时麦克风 → fd 3）→ core.mjs 按停顿切句 → whisper-server 识别 → translate 翻译
//   双路（--mic）：电脑声音 = 对方（Them），麦克风 = 我（Me）；字幕和记录标说话人，只有对方的话触发问题检测，
//   我的话只当问答上下文；外放时麦克风录到的对方回声按文字相似度丢掉（core.mjs createEchoGate）
//   终端实时打印「原文 / 译文」，同时写进 transcripts/<开始时间>.md
//
// 用法：node run.mjs [--lang auto|zh|en] [--mic] [--no-translate] [--no-window] [--no-qa] [--model 路径] [--out 记录目录] [--debug]
// 问题回答：config.json 里配 ModelFold API Key 后自动开（见 qa.mjs）
// 界面语言：环境变量 AIM_LANG=en|zh（默认英文，见 i18n.mjs）。应用版另设 AIM_APP=1：
//   输出 @@record <记录路径> / @@notice <级别> <代码> <文字> 控制行给主窗口解析；stdin 收 {"lang":"zh"} 实时切换语言
// 依赖：brew install whisper-cpp（应用版自带）；models/ggml-large-v3-turbo.bin（应用版由 --model 传入）；同目录编译好的 capture、translate、subtitle
import { spawn, execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createQA } from './qa.mjs'
import { t, setLang, getLang } from './i18n.mjs'
import { createSegmenter, createTranscriber, createEchoGate } from './core.mjs'

const DIR = path.dirname(fileURLToPath(import.meta.url))
const args = process.argv.slice(2)
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d }
const LANG = opt('--lang', 'auto')
const TRANSLATE = !args.includes('--no-translate')
const MIC = args.includes('--mic')
const MODEL = opt('--model', path.join(DIR, 'models/ggml-large-v3-turbo.bin'))
const OUT_DIR = opt('--out', path.join(DIR, 'transcripts'))   // 会议记录目录（应用版放到 ~/Documents/AI Meeting Notes）
const PORT = Number(process.env.AIM_WHISPER_PORT || 8178)
const DEBUG = args.includes('--debug')
const WINDOW = !args.includes('--no-window')
const APP = process.env.AIM_APP === '1'
const ctl = (line) => { if (APP) console.log('@@' + line) }   // 给主窗口的控制行（终端运行时不打）
const dbg = (s) => { if (DEBUG) console.error('[debug] ' + s) }

// ---------- 输出 ----------
fs.mkdirSync(OUT_DIR, { recursive: true })
const started = new Date()
const pad = (n) => String(n).padStart(2, '0')
const stamp = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
const outPath = path.join(OUT_DIR, `${started.getFullYear()}-${pad(started.getMonth() + 1)}-${pad(started.getDate())}_${pad(started.getHours())}${pad(started.getMinutes())}.md`)
fs.writeFileSync(outPath, t('record.title', { date: started.toLocaleString(getLang() === 'zh' ? 'zh-CN' : 'en-US', { hour12: false }) }) + '\n\n' +
  (MIC ? t('record.speakers') + '\n\n' : ''))
const lines = new Map()   // id → { t, text, tr, who }
const whoLabel = (who) => t(who === 'me' ? 'who.me' : 'who.them')
function flush(id) {
  const l = lines.get(id)
  if (!l || l.written || (TRANSLATE && l.tr === undefined)) return
  l.written = true
  const head = MIC ? `**[${l.t}] ${whoLabel(l.who)}:**` : `**[${l.t}]**`
  fs.appendFileSync(outPath, `${head} ${l.text}\n` + (l.tr ? `> ${l.tr}\n` : '') + '\n')
}

// ---------- 字幕窗口 ----------
let win = null
if (WINDOW) {
  win = spawn(path.join(DIR, 'subtitle'), [], { stdio: ['pipe', 'ignore', 'inherit'] })   // 继承 AIM_LANG
  win.stdin.on('error', () => {})
  win.on('exit', () => { win = null })   // 关掉窗口不影响后台记录
}
const toWin = (m) => { if (win) win.stdin.write(JSON.stringify(m) + '\n') }
// 字幕窗底部状态行：记住文案键，切换语言时按新语言重发
let lastStatus = null
const winStatus = (key, params = {}) => { lastStatus = { key, params }; toWin({ type: 'status', text: t(key, params) }) }

// ---------- 问题提炼 + 回答（ModelFold 对话模型）----------
const qa = args.includes('--no-qa')
  ? { enabled: false, feed() {}, async drain() {} }
  : createQA({
      dir: DIR,
      dual: MIC,
      log: (s) => console.log(`\x1b[2m${s}\x1b[0m`),
      t, getLang,
      onError: (s) => { console.error(`\x1b[33m${s}\x1b[0m`); toWin({ type: 'status', text: s }) },
      // 账户/网络状态：字幕窗顶部横幅 + 日志（应用版收到 @@notice 控制行，积分不足 / Key 无效时弹框）
      onNotice: ({ level, code, text }) => {
        if (APP) ctl(`notice ${level} ${code} ${text.replace(/\n/g, ' ')}`)
        else console.log(`${level === 'ok' ? '✓' : '⚠'} ${text}`)
        toWin({ type: 'notice', level, text })
      },
      onAnswer: ({ q, a }) => {
        console.log(`\x1b[33m❓ ${q}\x1b[0m\n\x1b[32m💡 ${a}\x1b[0m`)
        toWin({ type: 'qa', t: stamp(new Date()), q, a })
        fs.appendFileSync(outPath, `> ❓ **${q}**\n>\n> 💡 ${a.replace(/\n/g, '\n> ')}\n\n`)
      },
    })

let cap = null   // 采集进程（下面 whisper-server 就绪后再启动）
let stopping = false

// ---------- whisper-server ----------
// 应用版自带 whisper-server（engine/whisper/），命令行版用 Homebrew 装的
const WHISPER_BIN = fs.existsSync(path.join(DIR, 'whisper/whisper-server')) ? path.join(DIR, 'whisper/whisper-server') : 'whisper-server'
// Intel 版（x64 Node，纯 CPU 识别，模型是 small / base）：线程数按物理核（2~8，超线程那一半不算，多了反而慢）；
//   小模型加简体提示词、关掉温度回退（见 core.mjs createTranscriber）。Apple 芯片版不变。
const X64 = process.arch === 'x64'
let THREADS = '8'
if (X64) {
  let n = 4
  try { n = Number(execFileSync('/usr/sbin/sysctl', ['-n', 'hw.physicalcpu']).toString().trim()) || 4 } catch {}
  THREADS = String(Math.min(8, Math.max(2, n)))
}
const server = spawn(WHISPER_BIN, ['-m', MODEL, '--host', '127.0.0.1', '--port', String(PORT), '-l', LANG, '-t', THREADS], { stdio: ['ignore', 'ignore', 'pipe'] })
let serverLog = ''
server.stderr.on('data', (d) => { serverLog = (serverLog + d).slice(-4000) })
server.on('error', (e) => { serverLog += '\n' + e.message })
// 不管怎么退出（包括意外崩溃）都把子进程带走，不留后台的 whisper-server / 字幕窗
process.on('exit', () => { for (const c of [() => server, () => cap, () => tr, () => win]) { try { c()?.kill() } catch {} } })
async function waitServer() {
  for (let i = 0; i < 240; i++) {
    try { if ((await fetch(`http://127.0.0.1:${PORT}/`)).ok) return } catch {}
    if (server.exitCode !== null) throw new Error(t('log.whisperExit', { log: serverLog }))
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error(t('log.whisperTimeout'))
}

const asr = createTranscriber({
  port: PORT, lang: LANG, small: X64,
  onError: (e) => console.error(t('log.asrFail', { msg: e.message })),
  debug: DEBUG ? dbg : null,
})

// ---------- 出字：一句识别完（麦克风的句子先过回声过滤）----------
function emitLine(id, who, startMs, text) {
  const ts = stamp(new Date(startMs))
  lines.set(id, { t: ts, text, who })
  console.log(`\x1b[2m[${ts}]\x1b[0m ${MIC ? whoLabel(who) + ': ' : ''}${text}`)
  lastStatus = null   // 字幕窗状态行改显示句数（字幕窗自己按语言渲染）
  toWin({ type: 'line', id, t: ts, text, ...(MIC ? { who } : {}) })
  qa.feed(ts, text, who)
  if (TRANSLATE && tr) tr.stdin.write(JSON.stringify({ id, text }) + '\n')
  else flush(id)
}

const gate = createEchoGate({
  onEmit: (h) => emitLine(h.payload.id, 'me', h.start, h.text),
  onDrop: (h, sim) => dbg(`回声丢弃（相似度 ${sim.toFixed(2)}）：${h.text}`),
})
let seq = 0
let backlogWarned = 0
function onUtterance(who, pcm, start, end) {
  const id = ++seq
  if (who === 'them' && MIC) gate.sysQueued(id, start, end)
  const job = asr.enqueue(pcm)
  // 识别排队太多（Intel 纯 CPU + 麦克风双路时可能）：一分钟最多提醒一次
  if (asr.backlog >= 4 && Date.now() - backlogWarned > 60000) {
    backlogWarned = Date.now()
    const key = X64 ? 'sub.backlogIntel' : 'sub.backlog'
    console.error(`\x1b[33m${t(key, { n: asr.backlog })}\x1b[0m`)
    winStatus(key, { n: asr.backlog })
  }
  job.then((text) => {
    if (who === 'them') {
      if (MIC) gate.sysDone(id, text)
      if (text) emitLine(id, 'them', start, text)
    } else if (text) gate.mic(start, end, text, { id })
  })
}
const segSys = createSegmenter({ onUtterance: (p, s, e) => onUtterance('them', p, s, e), onSpeaking: (s) => { if (MIC) gate.sysSpeaking(s) } })
const segMic = MIC ? createSegmenter({ onUtterance: (p, s, e) => onUtterance('me', p, s, e) }) : null
const gateTimer = MIC ? setInterval(() => gate.tick(), 1000) : null

// ---------- 翻译 ----------
let tr = null
if (TRANSLATE) {
  tr = spawn(path.join(DIR, 'translate'), [], { stdio: ['pipe', 'pipe', 'inherit'] })
  let buf = ''
  tr.stdout.on('data', (d) => {
    buf += d
    let i
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1)
      let m; try { m = JSON.parse(line) } catch { continue }
      if (m.id == null) continue
      const l = lines.get(m.id)
      if (!l) continue
      l.tr = m.text || ''
      if (m.text) { console.log(`   \x1b[36m${m.text}\x1b[0m`); toWin({ type: 'tr', id: m.id, text: m.text }) }
      flush(m.id)
    }
  })
}

// ---------- 采集 ----------
try { await waitServer() } catch (e) {
  console.error(t('log.startFail', { msg: e.message }))
  try { win?.kill() } catch {}
  try { tr?.kill() } catch {}
  try { server.kill() } catch {}
  process.exit(1)
}
cap = spawn(path.join(DIR, 'capture'), MIC ? ['--quiet', '--mic'] : ['--quiet'], { stdio: ['ignore', 'pipe', 'inherit', ...(MIC ? ['pipe'] : [])] })
cap.on('error', (e) => { console.error(t('log.startFail', { msg: e.message })); if (!stopping) { stopping = true; shutdown() } })
cap.stdout.on('data', (chunk) => segSys.push(chunk))
if (MIC) cap.stdio[3].on('data', (chunk) => segMic.push(chunk))
winStatus('sub.started')
ctl(`record ${outPath}`)
console.log('\n' + t('log.started', { lang: t('lang.' + LANG), mic: MIC ? t('log.startedMic') : '', tr: TRANSLATE ? t('log.startedTr') : '', qa: qa.enabled ? t('log.startedQa') : '', path: outPath }) +
  (APP ? '' : '\n' + t('log.ctrlC')) + '\n')

// 应用版：主窗口切换界面语言时从 stdin 发 {"lang":"zh"}，后续日志、字幕窗、问答提示词立即换语言（会议记录标题已写，不改）
if (APP) {
  let inBuf = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', (d) => {
    inBuf += d
    let i
    while ((i = inBuf.indexOf('\n')) >= 0) {
      const line = inBuf.slice(0, i); inBuf = inBuf.slice(i + 1)
      let m; try { m = JSON.parse(line) } catch { continue }
      if (!m.lang || m.lang === getLang()) continue
      setLang(m.lang)
      toWin({ type: 'lang', lang: getLang() })
      if (lastStatus) winStatus(lastStatus.key, lastStatus.params)
      console.log(t('log.langSwitched'))
    }
  })
  process.stdin.on('error', () => {})
}

function shutdown() {
  try { cap?.kill('SIGINT') } catch {}
  segSys.flush()
  segMic?.flush()
  asr.drain().then(() => { gate.flush(); clearInterval(gateTimer) })
    .then(() => new Promise((r) => setTimeout(r, 1500))).then(() => qa.drain()).then(() => {
      for (const id of lines.keys()) { const l = lines.get(id); if (l.tr === undefined) l.tr = ''; flush(id) }
      try { tr?.kill() } catch {}
      try { server.kill() } catch {}
      try { win?.kill() } catch {}
      console.log('\n' + t('log.stopped', { path: outPath }))
      process.exit(0)
    })
}
const onSignal = () => { if (stopping) return; stopping = true; console.error(t('log.stopping')); shutdown() }
process.on('SIGINT', onSignal)
process.on('SIGTERM', onSignal)
cap.on('exit', (code, sig) => { if (DEBUG || code) console.error(t('log.captureExit', { code: code ?? sig })); if (code && !stopping) { stopping = true; shutdown() } })
