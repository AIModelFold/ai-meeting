// AI Meeting · 问题提炼 + 回答：调 ModelFold 对话模型（OpenAI 兼容 /v1/chat/completions）
//
// 每来一句新文字稿就 feed() 进来；最近几句里像是有人提问时（问号 / 吗呢 / what how…），
// 带上最近几分钟的上下文请模型：找出还没回答过的问题，给出简短的建议回答（用提问的语言回答）。
// 配置：createQA({ config }) 直接传；或 config.json 的 modelfold.{base,api_key,model}，或环境变量 MODELFOLD_API_KEY / MODELFOLD_BASE / MODELFOLD_MODEL。
// 文案：调用方传 t(key, 参数) 和 getLang()（Mac 引擎用 ../i18n.mjs，Windows 版用 src/i18n.mjs，键名一致）。
// 本文件 Mac 引擎和 Windows 版共用：windows/scripts/sync-shared.mjs 会把它复制到 windows/src/engine/qa.mjs，改这里即可。
import fs from 'node:fs'
import path from 'node:path'

// 上下文预算（控制每次调用的花费）：从最新一句往回取，最多 CTX_LINES 句 / CTX_CHARS 字 / CTX_MS 时间，
// 双路（电脑声音 = 对方，麦克风 = 我）时对方前面的提问和我前面的回答都在里面，追问才接得上
const CTX_MS = 15 * 60 * 1000
const CTX_LINES = 60
const CTX_CHARS = 4000
const DEBOUNCE_MS = 1500             // 一句说完等一下，问题常常跨两句
const LOW_BALANCE = 20               // 余额低于这么多积分提前提醒一次
export const QUESTION_RE = /[?？]|[吗呢么]\s*[。，,.!！]?$|(什么|怎么|为什么|为啥|多少|几个|哪|是否|能不能|可不可以|有没有|要不要|是不是|如何)|(^|[.!?]\s+)(what|how|why|when|where|who|which|can|could|would|should|is|are|do|does|did|will)\b/i

export function loadConfig(dir) {
  let cfg = {}
  try { cfg = JSON.parse(fs.readFileSync(path.join(dir, 'config.json'), 'utf8')).modelfold || {} } catch {}
  return {
    base: (process.env.MODELFOLD_BASE || cfg.base || 'https://ai.modelfold.online/v1').replace(/\/$/, ''),
    apiKey: process.env.MODELFOLD_API_KEY || cfg.api_key || '',
    model: process.env.MODELFOLD_MODEL || cfg.model || 'deepseek-v4-1-flash',
  }
}

// 提示词跟界面语言走（模型两种都懂）；回答语言始终跟提问的语言一致——是要在会上照着说的
const PROMPTS = {
  zh: {
    system: `你是会议助手。输入是一场会议的实时文字稿（语音识别，可能有错字），最后几行是刚说的话。
任务：找出「最新几行」里有人提出的、需要回答的问题（不含寒暄、反问、已在文字稿里被回答的问题、以及「已回答过的问题」列表里的），为每个问题给一个简短、可以直接照着说的建议回答。
- 回答用问题的语言（中文问就中文答，英文问就英文答），2~4 句，先给结论
- 不知道具体事实时给出合理的思路或需要确认的点，不要编造数字
- 识别错字按上下文纠正后再写问题
只输出 JSON：{"questions":[{"q":"问题","a":"回答"}]}，没有问题就输出 {"questions":[]}`,
    transcript: '文字稿：', latest: '--- 最新 ---', answered: '已回答过的问题：', none: '（无）',
    them: '对方', me: '我',
    dual: `
文字稿分两个人：「对方」是电脑里传来的声音（例如面试官、客户），「我」是用户自己（麦克风）。
- 只找「对方」提出的问题；「我」说的话只当上下文
- 建议回答是给「我」接着说的：要接上「我」前面已经讲过的内容（保持一致、在此基础上补充，不要自相矛盾，也不要原样重复），追问要结合「对方」前面问过的问题来理解`,
  },
  en: {
    system: `You are a meeting assistant. The input is the live transcript of a meeting (speech recognition, may contain errors); the last lines are what was just said.
Task: find the questions raised in the "latest" lines that need an answer (skip small talk, rhetorical questions, questions already answered in the transcript, and anything in the "Already answered" list). For each one, give a short suggested answer the user can say as-is.
- Answer in the language the question was asked in (Chinese question → Chinese answer, English question → English answer), 2–4 sentences, conclusion first
- If you don't know specific facts, give a sensible approach or the points to confirm; never invent numbers
- Fix recognition errors from context before writing the question
Output JSON only: {"questions":[{"q":"question","a":"answer"}]}; if there are none, output {"questions":[]}`,
    transcript: 'Transcript:', latest: '--- latest ---', answered: 'Already answered:', none: '(none)',
    them: 'Them', me: 'Me',
    dual: `
The transcript has two speakers: "Them" is the sound coming from the computer (e.g. the interviewer or client), "Me" is the user (microphone).
- Only look for questions asked by Them; what Me says is context only
- The suggested answer is for Me to say next: build on what Me has already said (stay consistent, add to it, don't contradict it or simply repeat it), and read follow-up questions in the light of Them's earlier questions`,
  },
}
export function prompts(lang) { return PROMPTS[lang] || PROMPTS.en }

// onNotice({ level: 'error'|'warn'|'ok', code, text })：账户/网络状态变化时通知一次（同一状态不重复刷）
//   insufficient_credits 积分不足（问题回答暂停，下次有人提问时自动重试，充值后自动恢复）
//   invalid_key          Key 无效或已注销
//   network              连不上 ModelFold
//   low_balance          余额快用完
//   recovered            从上面的错误恢复
// dual：双路模式（feed 时带 who = 'them' | 'me'），只有对方的话触发问题检测，我的话只当上下文
export function createQA({ dir, config, dual = false, onAnswer, onError, onNotice, log = () => {}, t = (k) => k, getLang = () => 'en', fetchImpl = fetch }) {
  const cfg = config || loadConfig(dir)
  const history = []          // { at, t, text, who }
  const answered = []         // 已回答的问题，防重复
  let timer = null
  let pendingIdx = -1         // 待检查的最早一句
  let busy = false
  let again = false
  let state = 'ok'            // 当前账户/网络状态，变化时才通知
  let lowWarned = false

  function setState(code, level) {
    if (state === code) return
    const was = state
    state = code
    if (code === 'ok') { if (was !== 'ok') onNotice?.({ level: 'ok', code: 'recovered', text: t('notice.recovered') }) }
    else onNotice?.({ level, code, text: t('notice.' + code) })
  }

  if (!cfg.apiKey) {
    onError?.(t('log.qaNoKey'))
    return { enabled: false, feed() {}, async drain() {} }
  }
  log(t('log.qaOn', { model: cfg.model, base: cfg.base }))

  async function run() {
    if (busy) { again = true; return }
    busy = true
    try {
      const from = pendingIdx
      pendingIdx = -1
      const P = prompts(getLang())
      const user = buildUserMessage(from, P)
      lastRequest = user

      const r = await fetchImpl(`${cfg.base}/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${cfg.apiKey}` },
        body: JSON.stringify({ model: cfg.model, max_tokens: 800, temperature: 0.3,
          messages: [{ role: 'system', content: P.system + (dual ? P.dual : '') }, { role: 'user', content: user }] }),
        signal: AbortSignal.timeout(60000),
      })
      const j = await r.json().catch(() => ({}))
      const errType = j.error?.type || j.error?.code || j.error
      if (r.status === 402 || errType === 'insufficient_credits') {
        setState('insufficient_credits', 'error')
        return
      }
      if (r.status === 401 || errType === 'invalid_api_key') {
        setState('invalid_key', 'error')
        return
      }
      if (!r.ok || j.ok === false) throw new Error(j.error?.message || j.message || `HTTP ${r.status}`)
      setState('ok')
      const bal = Number(j.usage?.balance)
      if (Number.isFinite(bal) && bal < LOW_BALANCE && !lowWarned) {
        lowWarned = true
        onNotice?.({ level: 'warn', code: 'low_balance', text: t('notice.low_balance', { bal }) })
      }
      const content = String(j.choices?.[0]?.message?.content || '')
      const m = content.match(/\{[\s\S]*\}/)
      const list = m ? (JSON.parse(m[0]).questions || []) : []
      for (const { q, a } of list) {
        if (!q || !a || answered.includes(q)) continue
        answered.push(q)
        onAnswer({ q: String(q).trim(), a: String(a).trim(), credits: j.usage?.credits })
      }
    } catch (e) {
      // fetch 本身抛错 = 网络不通 / 超时
      if (e.name === 'TypeError' || e.name === 'TimeoutError' || e.name === 'AbortError') {
        setState('network', 'warn')
      } else onError?.(t('log.qaFail', { msg: e.message }))
    } finally {
      busy = false
      if (again) { again = false; schedule() }
    }
  }

  function schedule() {
    clearTimeout(timer)
    timer = setTimeout(run, DEBOUNCE_MS)
  }

  /** 选上下文：从最新往回取到预算用完；from 之后的新句子一定带上。双路时连续同一人的句子合成一段，标上说话人 */
  function pickContext(from) {
    const out = []
    let chars = 0
    const now = Date.now()
    for (let i = history.length - 1; i >= 0; i--) {
      const h = history[i]
      const must = from >= 0 && i >= from
      if (!must && (out.length >= CTX_LINES || chars + h.text.length > CTX_CHARS || now - h.at > CTX_MS)) break
      out.unshift({ ...h, i })
      chars += h.text.length
    }
    return out
  }

  function buildUserMessage(from, P) {
    const ctx = pickContext(from)
    const rows = []
    let prev = null
    for (const h of ctx) {
      const latest = from >= 0 && h.i === Math.max(from, ctx[0].i) && h.i >= from
      if (latest) { rows.push(P.latest); prev = null }
      if (dual) {
        const who = h.who === 'me' ? P.me : P.them
        if (prev && prev.who === who) prev.row.text += ' ' + h.text
        else { const row = { head: `[${h.t}] ${who}:`, text: h.text }; rows.push(row); prev = { who, row } }
      } else rows.push({ head: `[${h.t}]`, text: h.text })
    }
    const transcript = rows.map((r) => (typeof r === 'string' ? r : `${r.head} ${r.text}`)).join('\n')
    return `${P.transcript}\n${transcript}\n\n${P.answered}\n${answered.slice(-20).map((q) => '- ' + q).join('\n') || P.none}`
  }

  let lastRequest = ''
  return {
    enabled: true,
    feed(stampStr, text, who = 'them') {
      history.push({ at: Date.now(), t: stampStr, text, who })
      if (history.length > 400) {
        const n = history.length - 400
        history.splice(0, n)
        if (pendingIdx >= 0) pendingIdx = Math.max(0, pendingIdx - n)
      }
      if ((!dual || who !== 'me') && QUESTION_RE.test(text)) {
        if (pendingIdx < 0) pendingIdx = history.length - 1
        schedule()
      }
    },
    get lastRequest() { return lastRequest },   // 测试用：最近一次发给模型的文字稿
    buildUserMessage: (from = -1) => buildUserMessage(from, prompts(getLang())),
    // 结束时把还在排队的那次跑完
    async drain() {
      if (timer && pendingIdx >= 0) { clearTimeout(timer); await run() }
      while (busy) await new Promise((r) => setTimeout(r, 200))
    },
  }
}
