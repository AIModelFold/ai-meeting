// AI Meeting 引擎文案（英文 / 中文）：run.mjs、qa.mjs 输出的日志、字幕窗状态、会议记录标题都从这里取。
// 语言来自环境变量 AIM_LANG（应用按界面语言传入，默认英文）；运行中应用会通过 stdin 发 {"lang":"zh"} 实时切换。
// t('key', { 参数 }) → 当前语言的文字；{name} 占位符按参数替换。

export const LANGS = ['en', 'zh']

const STRINGS = {
  en: {
    'record.title': '# Meeting notes {date}',
    'record.speakers': '_Them = computer sound (the other side) · Me = microphone_',
    'who.them': 'Them',
    'who.me': 'Me',
    'sub.started': 'Started, waiting for sound…',
    'sub.backlog': 'Recognition is falling behind ({n} sentences waiting)',
    'sub.backlogIntel': 'Recognition is falling behind ({n} sentences waiting). If this keeps happening, switch to the Fast speech model or turn off the microphone',
    'lang.auto': 'auto (Chinese / English)',
    'lang.zh': 'Chinese',
    'lang.en': 'English',
    'log.started': 'AI Meeting started: speech language {lang}{mic}{tr}{qa}. Notes are written to {path}',
    'log.startedMic': ', microphone on (computer sound = Them, microphone = Me)',
    'log.startedTr': ', live translation on',
    'log.startedQa': ', Q&A on',
    'log.ctrlC': 'Press Ctrl+C to stop',
    'log.asrFail': 'Recognition failed: {msg}',
    'log.whisperExit': 'whisper-server exited:\n{log}',
    'log.whisperTimeout': 'whisper-server did not start in time',
    'log.startFail': 'Could not start: {msg}',
    'log.stopping': 'Stopping, saving notes…',
    'log.stopped': 'Stopped. Notes: {path}',
    'log.captureExit': 'System audio capture stopped (exit code {code})',
    'log.langSwitched': 'Language switched to English',
    'log.qaOn': 'Question answering on: {model} @ {base}',
    'log.qaNoKey': 'No ModelFold key set, question answering is off',
    'log.qaFail': 'Question answering failed: {msg}',
    'notice.insufficient_credits': 'Out of ModelFold credits, question answering paused (captions unaffected). Resumes automatically after top-up: ai.modelfold.online/account',
    'notice.invalid_key': 'ModelFold key is invalid or revoked, question answering paused. Put a valid key in the main window and start again',
    'notice.network': "Can't reach ModelFold (network problem). This question wasn't answered; it continues automatically when the network is back",
    'notice.low_balance': 'Only {bal} ModelFold credits left, please top up soon: ai.modelfold.online/account',
    'notice.recovered': 'Question answering resumed',
  },
  zh: {
    'record.title': '# 会议记录 {date}',
    'record.speakers': '_对方 = 电脑里的声音 · 我 = 麦克风_',
    'who.them': '对方',
    'who.me': '我',
    'sub.started': '已启动，等待声音…',
    'sub.backlog': '识别跟不上（积压 {n} 句）',
    'sub.backlogIntel': '识别跟不上（积压 {n} 句），持续出现的话请换「快速」识别模型或关掉麦克风',
    'lang.auto': '自动（中英）',
    'lang.zh': '中文',
    'lang.en': '英文',
    'log.started': 'AI Meeting 已启动：识别语言 {lang}{mic}{tr}{qa}。记录写入 {path}',
    'log.startedMic': '，麦克风开（电脑声音 = 对方，麦克风 = 我）',
    'log.startedTr': '，实时翻译开',
    'log.startedQa': '，问题回答开',
    'log.ctrlC': 'Ctrl+C 结束',
    'log.asrFail': '识别失败：{msg}',
    'log.whisperExit': 'whisper-server 退出了：\n{log}',
    'log.whisperTimeout': 'whisper-server 启动超时',
    'log.startFail': '启动失败：{msg}',
    'log.stopping': '正在结束，保存记录…',
    'log.stopped': '已结束，记录：{path}',
    'log.captureExit': '系统声音采集停止了（退出码 {code}）',
    'log.langSwitched': '界面语言已切换为中文',
    'log.qaOn': '问题回答已开：{model} @ {base}',
    'log.qaNoKey': '未配置 ModelFold Key，问题回答功能关闭',
    'log.qaFail': '问题回答失败：{msg}',
    'notice.insufficient_credits': 'ModelFold 积分不足，问题回答已暂停（字幕不受影响）。充值后自动恢复：ai.modelfold.online/account',
    'notice.invalid_key': 'ModelFold Key 无效或已注销，问题回答已暂停。请在主窗口换一个有效的 Key 后重新开始',
    'notice.network': '连不上 ModelFold（网络问题），这次问题没能回答，网络恢复后会自动继续',
    'notice.low_balance': 'ModelFold 积分只剩 {bal}，快用完了，建议尽快充值：ai.modelfold.online/account',
    'notice.recovered': '问题回答已恢复',
  },
}

let current = LANGS.includes(process.env.AIM_LANG) ? process.env.AIM_LANG : 'en'

export function setLang(lang) { current = LANGS.includes(lang) ? lang : 'en'; return current }
export function getLang() { return current }
export function keys(lang) { return Object.keys(STRINGS[lang] || {}) }

export function t(key, params = {}, lang = current) {
  const s = (STRINGS[lang] && STRINGS[lang][key]) ?? STRINGS.en[key] ?? key
  return s.replace(/\{(\w+)\}/g, (m, k) => (k in params ? String(params[k]) : m))
}
