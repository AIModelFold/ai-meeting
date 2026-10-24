// AI Meeting 引擎逻辑测试（不开窗口、不出声、不联网）：node --test test/
import test from 'node:test'
import assert from 'node:assert/strict'
import { createSegmenter, createEchoGate, similarity, createTranscriber } from '../core.mjs'
import { createQA } from '../qa.mjs'
import { t, setLang, keys } from '../i18n.mjs'

const RATE = 16000
const tone = (s, amp = 0.2) => { const b = Buffer.alloc(Math.round(RATE * s) * 2); for (let i = 0; i < b.length / 2; i++) b.writeInt16LE(Math.round(Math.sin(i / 8) * amp * 32767), i * 2); return b }
const silence = (s) => Buffer.alloc(Math.round(RATE * s) * 2)

/** 按 100ms 一块推进假时钟喂数据，模拟实时采集 */
function feed(seg, clock, buf) {
  const step = RATE * 0.1 * 2
  for (let o = 0; o < buf.length; o += step) { clock.t += 100; seg.push(buf.subarray(o, o + step)) }
}

test('切句：两句话 + 停顿，起止时间按采样推算', () => {
  const clock = { t: 0 }
  const got = [], speaking = []
  const seg = createSegmenter({ now: () => clock.t, onUtterance: (pcm, s, e) => got.push({ s, e, dur: pcm.length / 2 / RATE }), onSpeaking: (s) => speaking.push(s) })
  feed(seg, clock, Buffer.concat([silence(1), tone(1.5), silence(1), tone(2), silence(1)]))
  assert.equal(got.length, 2)
  assert.ok(Math.abs(got[0].s - 1000) <= 60, `第一句开始 ${got[0].s}`)
  assert.ok(Math.abs(got[0].e - 2500) <= 60, `第一句结束 ${got[0].e}`)
  assert.ok(Math.abs(got[1].s - 3500) <= 60, `第二句开始 ${got[1].s}`)
  assert.deepEqual(speaking.map((x) => x === null ? 'end' : 'start'), ['start', 'end', 'start', 'end'])
})

test('切句：连续讲超过 8 秒强制切，且不丢后半句', () => {
  const clock = { t: 0 }
  const got = []
  const seg = createSegmenter({ now: () => clock.t, onUtterance: (pcm, s, e) => got.push(pcm.length / 2 / RATE) })
  feed(seg, clock, Buffer.concat([tone(12), silence(1)]))
  assert.equal(got.length, 2)
  assert.ok(got[0] >= 7.9 && got[0] <= 8.1)
  assert.ok(got[1] > 3.5)
})

test('切句：flush 交出没说完的句子；静音不出句', () => {
  const clock = { t: 0 }
  const got = []
  const seg = createSegmenter({ now: () => clock.t, onUtterance: () => got.push(1) })
  feed(seg, clock, silence(3))
  assert.equal(got.length, 0)
  feed(seg, clock, tone(2))
  seg.flush()
  assert.equal(got.length, 1)
})

test('相似度：回声 vs 真回答', () => {
  assert.ok(similarity('What is our budget for the next quarter', 'What is our budget for the next quarter?') > 0.9)
  assert.ok(similarity('budget for the next quarter', 'Hello. What is our budget for the next quarter?') > 0.9)
  assert.ok(similarity('我们下个季度的预算是多少', '我们下个季度的预算是多少？') > 0.9)
  assert.ok(similarity('我们下季度预算是多少', '我们下个季度的预算是多少？') > 0.5, '识别略有出入也算回声')
  assert.ok(similarity('Our budget is about two million dollars', 'What is our budget for the next quarter?') < 0.5)
  assert.ok(similarity('大概两百万，主要花在研发上', '我们下个季度的预算是多少？') < 0.3)
  assert.equal(similarity('', 'abc'), 0)
})

test('回声过滤：麦克风先识别完也会等同时段的电脑声音，再判断丢弃 / 放行', () => {
  const clock = { t: 10000 }
  const emitted = [], dropped = []
  const g = createEchoGate({ now: () => clock.t, onEmit: (h) => emitted.push(h.text), onDrop: (h) => dropped.push(h.text) })
  // 电脑声音 1000~3000 在说，送识别中；麦克风 1050~3000 录到回声，先识别完
  g.sysQueued(1, 1000, 3000)
  g.mic(1050, 3000, 'What is our budget for the next quarter', { id: 2 })
  assert.equal(emitted.length + dropped.length, 0, '电脑声音还没识别完，先压着')
  g.sysDone(1, 'What is our budget for the next quarter?')
  assert.deepEqual(dropped, ['What is our budget for the next quarter'])
  // 我在 5000~8000 回答（电脑那边没声音）→ 直接放行
  g.mic(5000, 8000, 'About two million, mostly for R&D.', { id: 3 })
  assert.deepEqual(emitted, ['About two million, mostly for R&D.'])
  // 电脑声音一直在说（sysSpeaking 开着）→ 最多压 8 秒后放行
  g.sysSpeaking(9000)
  g.mic(9500, 11000, 'Sorry, go ahead', { id: 4 })
  assert.equal(emitted.length, 1)
  clock.t += 9000
  g.tick()
  assert.deepEqual(emitted, ['About two million, mostly for R&D.', 'Sorry, go ahead'])
})

test('回声过滤：顺序保持；flush 时全部判掉', () => {
  const clock = { t: 0 }
  const emitted = []
  const g = createEchoGate({ now: () => clock.t, onEmit: (h) => emitted.push(h.payload.id) })
  g.sysQueued(1, 0, 2000)
  g.mic(100, 2000, 'first', { id: 'a' })
  g.mic(5000, 6000, 'second', { id: 'b' })
  assert.deepEqual(emitted, [])
  g.flush()
  assert.deepEqual(emitted, ['a', 'b'])
})

test('识别队列：串行、过滤幻觉、出错返回空串', async () => {
  const order = []
  const fake = async (url, opt) => {
    const n = order.length
    order.push(n)
    await new Promise((r) => setTimeout(r, n === 0 ? 30 : 1))
    if (n === 2) throw new Error('boom')
    return { json: async () => ({ text: n === 1 ? ' (字幕由 Amara.org 社区提供) ' : ' hello   world ' }) }
  }
  let err = null
  const tr = createTranscriber({ port: 1, fetchImpl: fake, onError: (e) => { err = e.message } })
  const r = await Promise.all([tr.enqueue(silence(1)), tr.enqueue(silence(1)), tr.enqueue(silence(1))])
  assert.deepEqual(r, ['hello world', '', ''])
  assert.equal(err, 'boom')
  assert.equal(tr.backlog, 0)
})

function mockModel(reply) {
  const reqs = []
  const fetchImpl = async (url, opt) => {
    reqs.push(JSON.parse(opt.body))
    return { ok: true, status: 200, json: async () => ({ choices: [{ message: { content: JSON.stringify(reply(reqs.length)) } }], usage: { balance: 999 } }) }
  }
  return { reqs, fetchImpl }
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms))

test('双路问答：只有对方的话触发；追问时把对方前面的提问和我的回答都带上', async () => {
  setLang('en')
  const m = mockModel(() => ({ questions: [] }))
  const answers = []
  const qa = createQA({ config: { base: 'http://x/v1', apiKey: 'k', model: 'm' }, dual: true, t, getLang: () => 'en', fetchImpl: m.fetchImpl, onAnswer: (a) => answers.push(a) })
  qa.feed('10:00:01', 'Could you introduce your product background and tech stack?', 'them')
  await qa.drain()
  assert.equal(m.reqs.length, 1)
  qa.feed('10:00:09', 'Sure. It is a meeting assistant. We use Swift and local Whisper. What else?', 'me')   // 我说的话带问号也不触发
  await wait(1700)
  assert.equal(m.reqs.length, 1, '我的话只当上下文，不触发')
  qa.feed('10:00:30', 'What hard problems did you hit along the way?', 'them')
  await qa.drain()
  assert.equal(m.reqs.length, 2)
  const sys = m.reqs[1].messages[0].content, user = m.reqs[1].messages[1].content
  assert.match(sys, /Only look for questions asked by Them/)
  assert.match(user, /\[10:00:01\] Them: Could you introduce/)
  assert.match(user, /\[10:00:09\] Me: Sure\. It is a meeting assistant/)
  assert.match(user, /--- latest ---\n\[10:00:30\] Them: What hard problems/)
})

test('双路问答：中文提示词与说话人标签；连续同一人的句子合成一段', async () => {
  const m = mockModel(() => ({ questions: [{ q: '遇到过什么难点？', a: '主要是本地实时识别的延迟。' }] }))
  const answers = []
  const qa = createQA({ config: { base: 'http://x/v1', apiKey: 'k', model: 'm' }, dual: true, t, getLang: () => 'zh', fetchImpl: m.fetchImpl, onAnswer: (a) => answers.push(a) })
  qa.feed('10:00:01', '能介绍一下你们产品的背景吗？', 'them')
  qa.feed('10:00:02', '还有技术栈。', 'them')
  await qa.drain()
  qa.feed('10:00:05', '我们做的是会议助手', 'me')
  qa.feed('10:00:07', '用 Swift 和本地 Whisper', 'me')
  qa.feed('10:00:20', '过程中遇到过什么难点？', 'them')
  await qa.drain()
  const user = m.reqs.at(-1).messages[1].content
  assert.match(m.reqs.at(-1).messages[0].content, /只找「对方」提出的问题/)
  assert.match(user, /\[10:00:01\] 对方: 能介绍一下你们产品的背景吗？ 还有技术栈。/)
  assert.match(user, /\[10:00:05\] 我: 我们做的是会议助手 用 Swift 和本地 Whisper/)
  assert.match(user, /--- 最新 ---\n\[10:00:20\] 对方: 过程中遇到过什么难点？/)
  assert.match(user, /已回答过的问题：\n- 遇到过什么难点？/)
  assert.equal(answers.filter((a) => a.q === '遇到过什么难点？').length, 1)
})

test('问答上下文有上限（控制花费），最新的问题一定带上', async () => {
  const m = mockModel(() => ({ questions: [] }))
  const qa = createQA({ config: { base: 'http://x/v1', apiKey: 'k', model: 'm' }, dual: true, t, getLang: () => 'en', fetchImpl: m.fetchImpl, onAnswer: () => {} })
  for (let i = 0; i < 200; i++) qa.feed('10:00:00', `line ${i} ` + 'x'.repeat(80), i % 2 ? 'me' : 'them')
  qa.feed('10:05:00', 'So what is the final price?', 'them')
  await qa.drain()
  const user = m.reqs.at(-1).messages[1].content
  assert.ok(user.length < 6000, `上下文 ${user.length} 字`)
  assert.match(user, /So what is the final price\?/)
  assert.doesNotMatch(user, /line 0 /)
})

test('单路（不录麦克风）：行为同以前，所有句子都可能触发、不标说话人', async () => {
  const m = mockModel(() => ({ questions: [] }))
  const qa = createQA({ config: { base: 'http://x/v1', apiKey: 'k', model: 'm' }, t, getLang: () => 'en', fetchImpl: m.fetchImpl, onAnswer: () => {} })
  qa.feed('10:00:01', 'What is the plan?')
  await qa.drain()
  const r = m.reqs[0]
  assert.doesNotMatch(r.messages[0].content, /Them/)
  assert.match(r.messages[1].content, /--- latest ---\n\[10:00:01\] What is the plan\?/)
})

test('引擎文案：中英键一致', () => {
  assert.deepEqual(keys('en').sort(), keys('zh').sort())
  setLang('zh'); assert.equal(t('who.me'), '我')
  setLang('en'); assert.equal(t('who.me'), 'Me')
})
