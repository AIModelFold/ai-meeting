// AI Meeting 引擎共用逻辑（Mac 的 run.mjs 和 Windows 版共用；windows/scripts/sync-shared.mjs 会复制到 windows/src/engine/core.mjs，改这里即可）
//
//   createSegmenter  按停顿把 16kHz 单声道 PCM 切成一句一句（自适应噪声门限）
//   createTranscriber 串行调 whisper-server /inference，过滤常见幻觉句
//   createEchoGate   麦克风回声过滤：外放时麦克风会把电脑里对方的声音再录一遍，
//                    麦克风这句和同一时间段电脑声音的识别文字高度相似（字符二元组重合率 ≥ 阈值）就丢掉
//   similarity / wav 小工具

export const RATE = 16000
const FRAME = RATE * 0.03             // 30ms 一帧（采样点数）
const FRAME_MS = 30
export const END_SILENCE_MS = 700     // 停顿这么久算一句结束
export const MAX_UTTER_S = 8          // 一句最长 8 秒，超了强制切（连续讲话时也能及时出字）
export const MIN_UTTER_S = 0.6

/**
 * onUtterance(pcm, startMs, endMs)：切出一句
 * onSpeaking(startMs | null)：开始说话 / 这一句结束（回声过滤要知道电脑声音是不是正在说）
 * now()：当前时间（毫秒），测试时注入假时钟；每个 chunk 的最后一帧算作 now()，往前每帧减 30ms
 */
export function createSegmenter({ onUtterance, onSpeaking = () => {}, now = () => Date.now(), minRms = 0.01 }) {
  let pending = Buffer.alloc(0)
  let utter = []
  let speaking = false
  let silentMs = 0
  let noise = 0.003                   // 背景噪声电平，自适应
  let startMs = 0
  let level = 0                       // 最近一帧电平（界面电平表用）

  function cut(endMs) {
    const dur = utter.length * FRAME_MS / 1000
    if (dur >= MIN_UTTER_S) onUtterance(Buffer.concat(utter), startMs, endMs)
    utter = []
  }

  function push(chunk) {
    pending = pending.length ? Buffer.concat([pending, chunk]) : Buffer.from(chunk)
    const bytes = FRAME * 2
    const frames = Math.floor(pending.length / bytes)
    const tEnd = now()
    for (let k = 0; k < frames; k++) {
      const f = pending.subarray(k * bytes, (k + 1) * bytes)
      const ft = tEnd - (frames - 1 - k) * FRAME_MS
      let sum = 0
      for (let i = 0; i < f.length; i += 2) { const v = f.readInt16LE(i) / 32768; sum += v * v }
      const rms = Math.sqrt(sum / FRAME)
      level = rms
      const isSpeech = rms > Math.max(minRms, noise * 3)
      if (!isSpeech) noise = noise * 0.995 + rms * 0.005

      if (isSpeech) {
        if (!speaking) { speaking = true; startMs = ft - FRAME_MS; onSpeaking(startMs) }
        silentMs = 0
      } else if (speaking) {
        silentMs += FRAME_MS
      }
      if (speaking) utter.push(Buffer.from(f))

      const dur = utter.length * FRAME_MS / 1000
      if (speaking && (silentMs >= END_SILENCE_MS || dur >= MAX_UTTER_S)) {
        const ended = silentMs >= END_SILENCE_MS
        cut(ended ? ft - silentMs : ft)
        silentMs = 0
        if (ended) { speaking = false; onSpeaking(null) }
        else startMs = ft                       // 强制切的那句后面还在说话
      }
    }
    pending = pending.subarray(frames * bytes)
  }

  /** 结束时把没切完的那句交出去 */
  function flush() {
    if (speaking) { cut(now()); speaking = false; onSpeaking(null) }
    utter = []
  }

  return { push, flush, get speaking() { return speaking }, get startMs() { return startMs }, get level() { return level } }
}

export function wav(pcm) {
  const h = Buffer.alloc(44)
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8)
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22)
  h.writeUInt32LE(RATE, 24); h.writeUInt32LE(RATE * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34)
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40)
  return Buffer.concat([h, pcm])
}

// Whisper 在纯噪声上常见的「幻觉」句子，丢掉
export const HALLUCINATION = /^(\s*[\[(（【].*[\])）】]\s*|.*(字幕|subtitles? by|thanks? for watching|请不吝点赞|订阅|amara\.org).*)$/i
const ZH_PROMPT = '以下是普通话的句子。'

/**
 * 识别按顺序串行（GPU / CPU 一次一段最快），句子排队。enqueue(pcm) → Promise<文字（空串 = 没识别出 / 幻觉）>
 * small：小模型（Intel / Windows 纯 CPU）——关掉温度回退（噪声段反复重解码会卡住后面所有句子），非英文加简体提示词
 */
export function createTranscriber({ port, lang = 'auto', small = false, onError = () => {}, debug = null, fetchImpl = fetch }) {
  let queue = Promise.resolve()
  let waiting = 0
  function enqueue(pcm) {
    waiting++
    const job = queue.then(async () => {
      const t0 = Date.now()
      try {
        const fd = new FormData()
        fd.append('file', new Blob([wav(pcm)], { type: 'audio/wav' }), 'a.wav')
        fd.append('response_format', 'json')
        fd.append('temperature', '0')
        if (small) {
          fd.append('temperature_inc', '0')
          if (lang !== 'en') fd.append('prompt', ZH_PROMPT)
        }
        const r = await fetchImpl(`http://127.0.0.1:${port}/inference`, { method: 'POST', body: fd })
        const j = await r.json()
        const text = String(j.text || '').replace(/\s+/g, ' ').trim()
        debug?.(`${(pcm.length / 2 / RATE).toFixed(1)}s → ${((Date.now() - t0) / 1000).toFixed(1)}s: ${JSON.stringify(text)}`)
        if (!text || HALLUCINATION.test(text) || (small && text.includes('以下是普通话'))) return ''   // 小模型偶尔把提示词原样吐出来
        return text
      } catch (e) {
        onError(e)
        return ''
      } finally { waiting-- }
    })
    queue = job
    return job
  }
  return { enqueue, drain: () => queue, get backlog() { return waiting } }
}

// ---------- 回声过滤 ----------
export function normText(s) { return String(s).toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '') }

/** a 的字符二元组有多少比例出现在 b 里（0~1）。a = 麦克风这句，b = 同时段电脑声音的文字 */
export function similarity(a, b) {
  const A = normText(a), B = normText(b)
  if (!A || !B) return 0
  if (A.length < 2) return B.includes(A) ? 1 : 0
  const grams = (s) => { const m = new Map(); for (let i = 0; i < s.length - 1; i++) { const g = s.slice(i, i + 2); m.set(g, (m.get(g) || 0) + 1) } return m }
  const ga = grams(A), gb = grams(B)
  let hit = 0, tot = 0
  for (const [g, n] of ga) { tot += n; hit += Math.min(n, gb.get(g) || 0) }
  return hit / tot
}

/**
 * 麦克风的句子先压一下，等同一时间段电脑声音的句子识别完再判断：像电脑声音的回声就丢（onDrop），否则放行（onEmit）。
 *   sysQueued(id, start, end) 电脑声音一句送去识别   sysDone(id, text) 识别完
 *   sysSpeaking(start | null) 电脑声音正在说 / 说完   mic(start, end, text, payload) 麦克风一句识别完
 *   tick() 定时调用（超时放行）  flush() 结束时全部判掉
 * 时间窗：麦克风这句前后 windowMs 内的电脑声音都拿来比；最多压 maxHoldMs（电脑声音一直在说也不会无限等）
 */
export function createEchoGate({ onEmit, onDrop = () => {}, windowMs = 2000, maxHoldMs = 8000, threshold = 0.5, now = () => Date.now() }) {
  const sysPending = new Map()
  const sysLines = []
  let sysOpen = null
  const holds = []

  function prune() {
    const keepFrom = now() - 60000
    while (sysLines.length && sysLines[0].end < keepFrom) sysLines.shift()
  }

  function release(force = false) {
    while (holds.length) {
      const h = holds[0]
      const lo = h.start - windowMs, hi = h.end + windowMs
      const waiting = [...sysPending.values()].some((p) => p.start <= hi && p.end >= lo) || (sysOpen !== null && sysOpen <= hi)
      if (waiting && !force && now() - h.readyAt < maxHoldMs) return
      holds.shift()
      const ref = sysLines.filter((s) => s.start <= hi && s.end >= lo).map((s) => s.text).join(' ')
      const sim = ref ? similarity(h.text, ref) : 0
      if (sim >= threshold) onDrop(h, sim)
      else onEmit(h, sim)
    }
  }

  return {
    sysQueued(id, start, end) { sysPending.set(id, { start, end }) },
    sysDone(id, text) {
      const p = sysPending.get(id)
      sysPending.delete(id)
      if (p && text) { sysLines.push({ ...p, text }); prune() }
      release()
    },
    sysSpeaking(start) { sysOpen = start; if (start === null) release() },
    mic(start, end, text, payload) { holds.push({ start, end, text, payload, readyAt: now() }); release() },
    tick() { release() },
    flush() { release(true) },
    get holding() { return holds.length },
  }
}
