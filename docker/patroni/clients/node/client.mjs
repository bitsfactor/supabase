// postgres.js 持续写客户端。连接设置照抄 xvideo(src/data-access/database.ts)。
// 环境:PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE CLIENT_NAME GID_BASE WORKERS INTERVAL_MS
import postgres from 'postgres'

const E = process.env
const name = E.CLIENT_NAME || 'node'
const workers = Number(E.WORKERS || 2)
const interval = Number(E.INTERVAL_MS || 20)
const gidBase = Number(E.GID_BASE || 1)
// 三个服务的连接选项原样照抄(postgres.js 3.4.9):
//  xvideo   src/data-access/database.ts:max 10 / idle_timeout 300 / connect_timeout 15 / statement_timeout 30s
//  ximage   src/data-access/database.ts:同上再加 keep_alive 15(pool_max 另配)
//  user-center lib/db.ts:max 10 / idle_timeout 30 / connect_timeout 10,无 statement_timeout,keep_alive 缺省 60
const PROFILES = {
  xvideo: { max: 10, idle_timeout: 300, connect_timeout: 15, connection: { statement_timeout: 30_000 } },
  ximage: { max: 10, idle_timeout: 300, connect_timeout: 15, keep_alive: 15, connection: { statement_timeout: 30_000 } },
  usercenter: { max: 10, idle_timeout: 30, connect_timeout: 10, connection: { search_path: 'public' } },
}
const profile = PROFILES[E.NODE_PROFILE || 'xvideo']
const sql = postgres({
  host: E.PGHOST, port: Number(E.PGPORT || 5433), user: E.PGUSER || 'supabase_admin',
  password: E.PGPASSWORD, database: E.PGDATABASE || 'postgres', onnotice: () => {},
  ...profile,
  ...(E.CONNECT_TIMEOUT ? { connect_timeout: Number(E.CONNECT_TIMEOUT) } : {}),
  // 缺省的重连退避随失败次数指数增长、最长约 20 秒;NODE_BACKOFF=fast 换成封顶 2 秒(验证用)
  ...(E.NODE_BACKOFF === 'fast' ? { backoff: (n) => Math.min(0.2 * 2 ** n, 2) } : {}),
  ...(E.TSA ? { target_session_attrs: E.TSA } : {}),
  ...(E.NODE_OPTS ? JSON.parse(E.NODE_OPTS) : {}),
})
const now = () => Date.now() / 1000
let stop = false
let lastAck = null, maxGap = 0, maxAttempt = 0, ok = 0, failedAttempts = 0
const gaps = [], fails = [], acked = {}
const timeline = {}   // 逐秒:成功数与各错误码的数量(TIMELINE=1 时随汇总输出)
const tl = (k) => { const s = Math.floor(now()); (timeline[s] ||= {})[k] = (timeline[s][k] || 0) + 1 }
function ack() { const t = now(); const g = lastAck === null ? 0 : t - lastAck; if (g > maxGap) maxGap = g; if (g > 1) gaps.push([+lastAck.toFixed(3), +t.toFixed(3)]); lastAck = t; ok++ }

async function worker(w) {
  const gid = gidBase + w
  let n = 0
  acked[gid] = 0
  while (!stop) {
    const t0 = now()
    try {
      await sql.begin(async (tx) => {
        await tx`insert into pt_load (seq, client, ts) values (${gid * 1e9 + n}, ${name}, now()) on conflict do nothing`
        await tx`select pg_sleep(0.01)`   // 事务内停一下,让「事务进行中被掐」真实发生
      })
      ack(); n++; acked[gid] = n; tl('ok')
    } catch (e) {
      failedAttempts++; tl(String(e.code || e.name || 'err').slice(0, 24))
      if (fails.length < 30) fails.push({ t: +t0.toFixed(3), dur: +(now() - t0).toFixed(3), err: String(e.code || e.message).slice(0, 80) })
    }
    const d = now() - t0; if (d > maxAttempt) maxAttempt = d
    await new Promise((r) => setTimeout(r, interval))
  }
}
const tasks = Array.from({ length: workers }, (_, i) => worker(i))
function done() {
  stop = true
  const t = now(); const tail = lastAck === null ? 0 : t - lastAck; if (tail > maxGap) maxGap = tail
  Promise.race([Promise.all(tasks), new Promise((r) => setTimeout(r, 15000))]).then(() => {
    console.log('SUMMARY ' + JSON.stringify({ client: name, ok, failedAttempts, maxAckGapS: +maxGap.toFixed(2), maxAttemptS: +maxAttempt.toFixed(2), stray, timeline: E.TIMELINE ? timeline : undefined, gaps, fails, acked }))
    process.exit(0)
  })
}
// 驱动在连接被掐时可能在 await 之外抛错;记一笔、不让进程退出(服务里同样要有这道兜底)
let stray = 0
process.on('uncaughtException', (e) => { stray++; if (fails.length < 30) fails.push({ t: +now().toFixed(3), dur: 0, err: 'uncaught ' + String(e.code || e.message).slice(0, 60) }) })
process.on('unhandledRejection', (e) => { stray++; if (fails.length < 30) fails.push({ t: +now().toFixed(3), dur: 0, err: 'unhandled ' + String((e && (e.code || e.message)) || e).slice(0, 60) }) })
process.on('SIGTERM', done); process.on('SIGINT', done)
