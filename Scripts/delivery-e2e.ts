/**
 * Delivery and status, end to end: the real app (a Debug build) in a simulator of its own,
 * against a throwaway Otto server (otto-core's otto/tests/apptwin.ts) that can be stopped,
 * restarted and asked to reply. Each scenario prints PASS or FAIL.
 *
 *   OTTO_CORE=<otto-core checkout> SIM=<simulator udid> APP=<path to Otto.app> bun Scripts/delivery-e2e.ts [offline|killed|tap|missed|read|wallet|share|edit|gap|approval|tapread|oldedit|photo|corrupt|all]
 *
 * Use a simulator made for it (`xcrun simctl create`): the app is reinstalled, so its thread is wiped.
 */
import { readFileSync, mkdirSync, writeFileSync } from 'fs'
import { join } from 'path'
const { startTwin, waitFor } = await import(join(process.env.OTTO_CORE!, 'otto/tests/apptwin.ts'))
type Twin = Awaited<ReturnType<typeof startTwin>>
const DEV = process.env.SIM!
const BUNDLE = 'dev.otto.app'
const sh = (...a: string[]) => { const p = Bun.spawnSync(a); return String(p.stdout).trim() }
const container = () => sh('xcrun', 'simctl', 'get_app_container', DEV, BUNDLE, 'data')
const thread = (): any[] => { try { return JSON.parse(readFileSync(join(container(), 'Library/Application Support/chat-otto-server.json'), 'utf8')) } catch { return [] } }
let twin: Twin
const launch = (...extra: string[]) => sh('xcrun', 'simctl', 'launch', '--terminate-running-process', DEV, BUNDLE,
  '-serverURL', twin.url, '-serverToken', twin.token, '-onboarded', 'YES', '-noNotificationPrompt', ...extra)
const kill = () => sh('xcrun', 'simctl', 'terminate', DEV, BUNDLE)
const results: [string, boolean, string][] = []
const check = (name: string, ok: boolean, detail = '') => { results.push([name, ok, detail]); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} ${detail}`) }
const mine = (text: string): any => thread().find(m => m.from === 'me' && m.text === text)
const count = (text: string) => twin.delivered.filter((d: any) => d.content.includes(text)).length

// fresh app data
sh('xcrun', 'simctl', 'uninstall', DEV, BUNDLE)
sh('xcrun', 'simctl', 'install', DEV, process.env.APP!)
twin = await startTwin()
launch(); await Bun.sleep(6000); kill()   // the first launch after an install is slow
const scenario = process.argv[2] ?? 'all'

if (scenario === 'all' || scenario === 'offline') {
  await twin.stop()
  launch('-e2eSend', 'offline one')
  await waitFor(() => mine('offline one'), 20000)
  check('offline: shows Sending', mine('offline one')?.pending === true && !mine('offline one')?.failed, JSON.stringify(mine('offline one') ?? null))
  await Bun.sleep(62000)
  check('offline: a minute on, Not delivered', mine('offline one')?.failed === true)
  twin = await twin.restart()
  await waitFor(() => !mine('offline one')?.pending, 20000)
  await Bun.sleep(1500)
  check('offline: delivered on reconnect', !mine('offline one')?.pending && !mine('offline one')?.failed, JSON.stringify(mine('offline one')))
  check('offline: reached the session once', count('offline one') === 1, String(count('offline one')))
}

if (scenario === 'all' || scenario === 'killed') {
  await twin.stop()
  launch('-e2eSend', 'killed one')
  await waitFor(() => mine('killed one'), 20000)
  await Bun.sleep(1000)
  kill()
  twin = await twin.restart()
  launch()
  await waitFor(() => count('killed one') > 0, 20000)
  await Bun.sleep(2000)
  check('killed: pending survives the app being killed', count('killed one') === 1, String(count('killed one')))
  check('killed: status cleared', !mine('killed one')?.pending)
}

if (scenario === 'all' || scenario === 'tap') {
  await twin.call('reply', { chat_id: 'app', text: 'draft ready', buttons: [{ label: 'send ✓', data: 'send the draft' }] })
  launch()
  await waitFor(() => thread().find(m => m.text === 'draft ready'), 15000)
  await twin.stop()
  launch('-e2eTapLast')
  await waitFor(() => mine('send ✓'), 20000)
  await Bun.sleep(1000)
  check('tap: offline tap is pending', mine('send ✓')?.pending === true, JSON.stringify(mine('send ✓') ?? null))
  kill()
  twin = await twin.restart()
  launch()
  await waitFor(() => count('send the draft') > 0, 20000)
  await Bun.sleep(2000)
  check('tap: delivered once after kill and reconnect', count('send the draft') === 1, String(count('send the draft')))
  check('tap: status cleared', !mine('send ✓')?.pending)
}

if (scenario === 'all' || scenario === 'missed') {
  kill()
  await twin.call('reply', { chat_id: 'app', text: 'missed A' })
  await twin.call('reply', { chat_id: 'app', text: 'missed B\n\nmissed C' })
  launch()
  await waitFor(() => thread().find(m => m.text === 'missed C'), 15000)
  await Bun.sleep(2000)
  const t = thread().map(m => m.text)
  check('missed: all replies, in order', t.indexOf('missed A') >= 0 && t.indexOf('missed A') < t.indexOf('missed B') && t.indexOf('missed B') < t.indexOf('missed C'), JSON.stringify(t.slice(-4)))
  launch()
  await Bun.sleep(5000)
  check('missed: no duplicates after relaunch', thread().filter(m => m.text === 'missed A').length === 1)
}

if (scenario === 'all' || scenario === 'read') {
  launch('-e2eSend', 'read me')
  const d = await waitFor(() => twin.delivered.find((x: any) => x.content === 'read me'), 20000)
  await Bun.sleep(1000)
  check('read: Delivered, not Read, before Otto takes it in', !mine('read me')?.pending && !mine('read me')?.read)
  await twin.call('reply', { chat_id: 'app', text: 'unrelated proactive line' })
  const dir = join(twin.state, '..', '..', '.claude', 'projects', 'x')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'r.jsonl'), JSON.stringify({ message_id: d?.meta.message_id }) + '\n')
  await twin.hook({ hook_event_name: 'PreToolUse', tool_name: 'reply', transcript_path: join(dir, 'r.jsonl') })
  await waitFor(() => mine('read me')?.read, 10000)
  check('read: Read once the session has it', mine('read me')?.read === true)
}

if (scenario === 'all' || scenario === 'wallet') {
  await twin.stop()
  launch('-e2eWallet', '€4.20')
  await waitFor(() => thread().find(m => m.wallet), 30000)
  await Bun.sleep(12000)   // past sendAndConfirm's 10s
  const w = () => thread().find(m => m.wallet)
  check('wallet: an offline payment is kept pending', w()?.pending === true, JSON.stringify(w() ?? null))
  twin = await twin.restart()
  launch()
  await waitFor(() => twin.delivered.some((d: any) => d.meta.wallet_amount === '€4.20'), 20000)
  await Bun.sleep(2000)
  check('wallet: filed once on reconnect', twin.delivered.filter((d: any) => d.meta.wallet_amount === '€4.20').length === 1)
  check('wallet: status cleared', !w()?.pending)
}

if (scenario === 'all' || scenario === 'share') {
  launch('-e2eShare', 'shared line')
  await waitFor(() => count('shared line') > 0, 20000)
  await Bun.sleep(2000)
  launch()
  await Bun.sleep(5000)
  check('share: handed over once, kept once', count('shared line') === 1 && thread().filter(m => m.text === 'shared line').length === 1,
    `${count('shared line')} ${thread().filter(m => m.text === 'shared line').length}`)
}

if (scenario === 'all' || scenario === 'edit') {
  await twin.call('reply', { chat_id: 'app', text: 'meet at 6pm, bring the keys' })
  launch()
  const m = await waitFor(() => thread().find(x => x.text === 'meet at 6pm, bring the keys'), 15000)
  kill()
  await twin.call('edit_message', { chat_id: 'app', message_id: m?.serverID, text: 'meet at 6pm' })
  launch()
  await waitFor(() => thread().find(x => x.serverID === m?.serverID)?.text === 'meet at 6pm', 15000)
  check('edit: a missed edit that shortens a reply lands', thread().find(x => x.serverID === m?.serverID)?.text === 'meet at 6pm')
}

if (scenario === 'all' || scenario === 'gap') {
  kill()
  for (let i = 0; i < 60; i++) await twin.call('reply', { chat_id: 'app', text: `backlog ${i}` })
  launch()
  await waitFor(() => thread().filter(m => m.text?.startsWith('backlog ')).length === 60, 30000)
  check('gap: more than 50 missed replies all arrive', thread().filter(m => m.text?.startsWith('backlog ')).length === 60,
    String(thread().filter(m => m.text?.startsWith('backlog ')).length))
  // The same with a message of yours sent right on reconnect, inside the newest 50: no false continuity.
  kill()
  for (let i = 0; i < 60; i++) await twin.call('reply', { chat_id: 'app', text: `second backlog ${i}` })
  await twin.stop()
  launch('-e2eSend', 'hello again')   // offline: it goes up with the reconnect, next to the catch-up
  await waitFor(() => mine('hello again'), 20000)
  twin = await twin.restart()
  await waitFor(() => thread().filter(m => m.text?.startsWith('second backlog ')).length === 60, 30000)
  check('gap: a fresh message of yours in the page does not hide the hole', thread().filter(m => m.text?.startsWith('second backlog ')).length === 60,
    String(thread().filter(m => m.text?.startsWith('second backlog ')).length))
}

if (scenario === 'all' || scenario === 'approval') {
  launch('-e2eDecide', 'no-such-approval')
  const decided = () => { try { return readFileSync(join(container(), 'Library/Application Support/e2e-decided'), 'utf8') } catch { return '' } }
  await waitFor(() => decided() !== '', 20000)
  check('approval: a decision on one the Mac no longer has comes back gone, not done', decided() === 'gone', decided())
  await waitFor(() => thread().some(m => /expired/.test(m.text)), 10000)
  check('approval: the thread says nothing was done', thread().some(m => m.from === 'otto' && /expired/.test(m.text)))
}

if (scenario === 'all' || scenario === 'tapread') {
  await twin.call('reply', { chat_id: 'app', text: 'ok?', buttons: [{ label: 'yes', data: 'tap read heal' }] })
  launch('-e2eTapLast')
  const d = await waitFor(() => twin.delivered.find((x: any) => x.content.includes('tap read heal')), 20000)
  kill()   // its read receipt will go nowhere
  const dir = join(twin.state, '..', '..', '.claude', 'projects', 'x')
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'tr.jsonl'), JSON.stringify({ message_id: d?.meta.message_id }) + '\n')
  await twin.hook({ hook_event_name: 'PreToolUse', tool_name: 'reply', transcript_path: join(dir, 'tr.jsonl') })
  launch()
  await waitFor(() => mine('yes')?.read, 15000)
  check('tap: a read receipt missed while away heals from history', mine('yes')?.read === true, JSON.stringify(mine('yes') ?? null))
}

if (scenario === 'all' || scenario === 'oldedit') {
  await twin.call('reply', { chat_id: 'app', text: 'old line to fix', verbatim: true })
  launch()
  const m = await waitFor(() => thread().find(x => x.text === 'old line to fix'), 15000)
  kill()
  for (let i = 0; i < 55; i++) await twin.call('reply', { chat_id: 'app', text: `edit filler ${i}`, verbatim: true })
  await twin.call('edit_message', { chat_id: 'app', message_id: m?.serverID, text: 'old line, fixed' })
  launch()
  await waitFor(() => thread().find(x => x.serverID === m?.serverID)?.text === 'old line, fixed', 20000)
  check('edit: a missed edit on a message older than the last 50 lands', thread().find(x => x.serverID === m?.serverID)?.text === 'old line, fixed')
  check('edit: and is not shown as a message of its own', thread().filter(x => x.text === 'old line, fixed').length === 1)
}

if (scenario === 'all' || scenario === 'photo') {
  launch('-e2ePhoto')
  await waitFor(() => twin.delivered.some((d: any) => d.content === 'e2e photo'), 20000)
  await Bun.sleep(1500)
  const raw = readFileSync(join(container(), 'Library/Application Support/chat-otto-server.json'), 'utf8')
  const m = JSON.parse(raw).find((x: any) => x.text === 'e2e photo')
  const { existsSync, readdirSync } = await import('fs')
  check('photo: delivered once and no longer pending', twin.delivered.filter((d: any) => d.content === 'e2e photo').length === 1 && !m?.pending)
  check('photo: the thread file keeps a flag, the JPEG lives in its own file', m?.photo === true && m?.image === undefined
    && existsSync(join(container(), `Library/Application Support/images/${m?.id}.jpg`)))
  // An older thread with the JPEG inline is moved out on the next save.
  kill()
  const thread0 = JSON.parse(raw)
  const legacy = { ...thread0.find((x: any) => x.text === 'e2e photo'), id: '0E0E0E0E-0000-4000-8000-000000000009', photo: undefined, image: Buffer.from(readFileSync(join(container(), `Library/Application Support/images/${m?.id}.jpg`))).toString('base64'), text: 'legacy photo' }
  writeFileSync(join(container(), 'Library/Application Support/chat-otto-server.json'), JSON.stringify([...thread0, legacy]))
  launch('-e2eSend', 'nudge a save')
  await waitFor(() => mine('nudge a save') && !readFileSync(join(container(), 'Library/Application Support/chat-otto-server.json'), 'utf8').includes(legacy.image.slice(0, 40)), 20000)
  const after = JSON.parse(readFileSync(join(container(), 'Library/Application Support/chat-otto-server.json'), 'utf8')).find((x: any) => x.text === 'legacy photo')
  check('photo: an inline photo from an older thread is moved out on the next save', after?.photo === true && after?.image === undefined
    && existsSync(join(container(), 'Library/Application Support/images/0E0E0E0E-0000-4000-8000-000000000009.jpg')))
}

if (scenario === 'all' || scenario === 'corrupt') {
  kill()
  const dir = join(container(), 'Library/Application Support')
  writeFileSync(join(dir, 'chat-otto-server.json'), '[{"from":"me","text":')   // cut off mid-write
  launch('-e2eSend', 'after the bad file')
  await waitFor(() => mine('after the bad file'), 20000)
  const { readdirSync } = await import('fs')
  check('corrupt: an unreadable thread is kept aside, not overwritten', readdirSync(dir).some(f => f.startsWith('chat-otto-server.json.unreadable-')))
}

kill()
await twin.stop()
console.log(`\n${results.filter(r => r[1]).length}/${results.length} passed`)
process.exit(results.every(r => r[1]) ? 0 : 1)
