import { client, xml } from '@xmpp/client'
import { useSyncExternalStore } from 'react'

import { requestToken } from '../bridge'
import { NS as OMEMO_NS, decrypt, encrypt, encryptFile, initOmemo } from './omemo'

export const DOMAIN = 'alo.ne'
export const MUC = 'conference.alo.ne'
const UPLOAD = 'upload.alo.ne'
const SERVICE = import.meta.env.VITE_XMPP_WS || 'wss://chat.alo.ne/xmpp-websocket'
export const DEFAULT_ROOMS = [`general@${MUC}`, `suggestions@${MUC}`, `premium@${MUC}`]

export type ChatMessage = {
  id: string
  stanzaId?: string
  from: string
  body: string
  ts: number
  mine: boolean
  encrypted?: boolean
  secure?: boolean
}

export type Occupant = { nick: string; role: string; affiliation: string }
export type Room = { jid: string; nick?: string; joined: boolean; error?: string; occupants: Record<string, Occupant>; messages: ChatMessage[] }
export type ArchivePolicy = 'always' | 'roster' | 'never'

export type ChatState = {
  status: 'offline' | 'connecting' | 'online'
  error: string
  username: string
  rooms: Record<string, Room>
  dms: Record<string, ChatMessage[]>
  unread: Record<string, number>
  active: string
  omemoOff: Record<string, boolean>
}

const readOmemoOff = (): Record<string, boolean> => {
  try { return JSON.parse(localStorage.getItem('omemo-off') || '{}') } catch { return {} }
}

let state: ChatState = {
  status: 'offline',
  error: '',
  username: '',
  rooms: {},
  dms: {},
  unread: {},
  active: DEFAULT_ROOMS[0],
  omemoOff: readOmemoOff(),
}
const listeners = new Set<() => void>()

export function getState() { return state }
export function setState(patch: Partial<ChatState> | ((s: ChatState) => Partial<ChatState>)) {
  state = { ...state, ...(typeof patch === 'function' ? patch(state) : patch) }
  listeners.forEach(listener => listener())
}
export function useChat() {
  return useSyncExternalStore(listener => { listeners.add(listener); return () => listeners.delete(listener) }, getState)
}

export const isRoomJid = (jid: string) => jid.endsWith(MUC) || !!state.rooms[jid]

export function setActive(jid: string) {
  setState(s => ({ active: jid, unread: { ...s.unread, [jid]: 0 } }))
}

export function setOmemo(peer: string, on: boolean) {
  setState(s => {
    const omemoOff = { ...s.omemoOff, [peer]: !on }
    try { localStorage.setItem('omemo-off', JSON.stringify(omemoOff)) } catch {}
    return { omemoOff }
  })
}

let xmpp: any = null
let connecting = false
let decryptQueue: Promise<unknown> = Promise.resolve()

const bare = (jid: string) => jid.split('/')[0]
const resource = (jid: string) => jid.split('/').slice(1).join('/')
const newId = () => Math.random().toString(36).slice(2) + Date.now().toString(36)

function updateRoom(jid: string, fn: (room: Room) => Room) {
  setState(s => {
    const room = s.rooms[jid] || { jid, joined: false, occupants: {}, messages: [] }
    return { rooms: { ...s.rooms, [jid]: fn(room) } }
  })
}

function bump(jid: string) {
  setState(s => s.active === jid ? {} : { unread: { ...s.unread, [jid]: (s.unread[jid] || 0) + 1 } })
}

function addDM(peer: string, message: ChatMessage, live = true) {
  setState(s => {
    const list = s.dms[peer] || []
    if (list.some(m => m.id === message.id)) return {}
    return { dms: { ...s.dms, [peer]: [...list, message].sort((a, b) => a.ts - b.ts) } }
  })
  if (!message.mine && live) bump(peer)
}

function messageTime(stanza: any) {
  const stamp = stanza.getChild('delay', 'urn:xmpp:delay')?.attrs.stamp
  return stamp ? Date.parse(stamp) : Date.now()
}

function handleGroupchat(stanza: any) {
  const room = bare(stanza.attrs.from)
  const nick = resource(stanza.attrs.from)
  const retract = stanza.getChild('retract', 'urn:xmpp:message-retract:1') || stanza.getChild('retract', 'urn:xmpp:message-retract:0')
  const retractId = retract?.attrs.id || stanza.getChild('apply-to', 'urn:xmpp:fasten:0')?.attrs.id
  if (retractId) {
    updateRoom(room, r => ({ ...r, messages: r.messages.filter(m => m.stanzaId !== retractId) }))
    return
  }
  const body = stanza.getChildText('body')
  if (!body || !nick) return
  const stanzaId = stanza.getChildren('stanza-id', 'urn:xmpp:sid:0').find((s: any) => s.attrs.by === room)?.attrs.id
  const message: ChatMessage = {
    id: stanza.attrs.id || newId(),
    stanzaId,
    from: nick,
    body,
    ts: messageTime(stanza),
    mine: nick === roomNick(room),
  }
  updateRoom(room, r => r.messages.some(m => m.id === message.id && m.from === nick) ? r : { ...r, messages: [...r.messages, message].slice(-500) })
  if (!message.mine && !stanza.getChild('delay', 'urn:xmpp:delay')) bump(room)
}

async function handleChat(stanza: any, sent = false, archived?: { id: string; ts: number }) {
  const encrypted = stanza.getChild('encrypted', OMEMO_NS)
  const body = stanza.getChildText('body')
  if (!body && !encrypted) return
  const peer = bare(sent ? stanza.attrs.to : stanza.attrs.from)
  if (!peer || isRoomJid(peer)) return
  const id = stanza.attrs.id || archived?.id || newId()
  if (archived && state.dms[peer]?.some(m => m.id === id)) return
  const sender = bare(stanza.attrs.from) || `${state.username}@${DOMAIN}`

  let text = body || ''
  let secure = false
  let unreadable = false
  if (encrypted) {
    const job = decryptQueue.then(() => decrypt(sender, encrypted))
    decryptQueue = job.catch(() => {})
    const plain = await job.catch(() => null)
    if (plain === '') return
    if (plain === null) unreadable = true
    else { text = plain; secure = true }
  }

  addDM(peer, {
    id,
    from: sent ? state.username : peer.split('@')[0],
    body: unreadable ? '' : text,
    ts: archived?.ts || messageTime(stanza),
    mine: sent,
    encrypted: unreadable,
    secure,
  }, !archived)
}

let archiveQuery = ''
let archiveQueue = Promise.resolve()

function handleArchived(result: any) {
  const forwarded = result.getChild('forwarded', 'urn:xmpp:forward:0')
  const inner = forwarded?.getChild('message')
  if (!inner || inner.attrs.type === 'groupchat') return
  const stamp = forwarded.getChild('delay', 'urn:xmpp:delay')?.attrs.stamp
  const sent = bare(inner.attrs.from || '') === `${state.username}@${DOMAIN}`
  archiveQueue = archiveQueue.then(() => handleChat(inner, sent, { id: result.attrs.id, ts: stamp ? Date.parse(stamp) : Date.now() })).catch(() => {})
}

async function loadHistory() {
  const roster = await xmpp.iqCaller.request(xml('iq', { type: 'get' }, xml('query', { xmlns: 'jabber:iq:roster' }))).catch(() => null)
  const contacts: string[] = (roster?.getChild('query', 'jabber:iq:roster')?.getChildren('item') || [])
    .map((item: any) => item.attrs.jid).filter((jid: string) => jid && jid.includes('@') && !jid.endsWith(MUC))
  setState(s => ({ dms: { ...Object.fromEntries(contacts.map(jid => [jid, []])), ...s.dms } }))

  if ((await getArchivePolicy()) === 'never') return
  const start = new Date(Date.now() - 86400000).toISOString()
  let after = ''
  for (let page = 0; page < 10; page++) {
    archiveQuery = newId()
    const reply = await xmpp.iqCaller.request(xml('iq', { type: 'set' }, xml('query', { xmlns: 'urn:xmpp:mam:2', queryid: archiveQuery },
      xml('x', { xmlns: 'jabber:x:data', type: 'submit' },
        xml('field', { var: 'FORM_TYPE', type: 'hidden' }, xml('value', {}, 'urn:xmpp:mam:2')),
        xml('field', { var: 'start' }, xml('value', {}, start))),
      xml('set', { xmlns: 'http://jabber.org/protocol/rsm' }, xml('max', {}, '100'), ...(after ? [xml('after', {}, after)] : []))))).catch(() => null)
    const fin = reply?.getChild('fin', 'urn:xmpp:mam:2')
    after = fin?.getChild('set', 'http://jabber.org/protocol/rsm')?.getChildText('last') || ''
    if (!fin || fin.attrs.complete === 'true' || !after) break
  }
  await archiveQueue
}

function handlePresence(stanza: any) {
  const from = stanza.attrs.from
  const room = bare(from)
  if (!isRoomJid(room)) return
  const nick = resource(from)
  if (stanza.attrs.type === 'error') {
    const text = stanza.getChild('error')?.getChildText('text', 'urn:ietf:params:xml:ns:xmpp-stanzas') || 'Could not join'
    updateRoom(room, r => ({ ...r, joined: false, error: text }))
    return
  }
  const item = stanza.getChild('x', 'http://jabber.org/protocol/muc#user')?.getChild('item')
  updateRoom(room, r => {
    const occupants = { ...r.occupants }
    if (stanza.attrs.type === 'unavailable') delete occupants[nick]
    else occupants[nick] = { nick, role: item?.attrs.role || 'participant', affiliation: item?.attrs.affiliation || 'none' }
    const self = nick === roomNick(room)
    return { ...r, occupants, joined: self ? stanza.attrs.type !== 'unavailable' : r.joined, error: undefined }
  })
}

export async function connect() {
  if (xmpp || connecting) return
  connecting = true
  setState({ status: 'connecting', error: '' })
  let first: { token: string; username: string }
  try {
    first = await requestToken()
  } catch (e: any) {
    setState({ status: 'offline', error: e?.message || 'Could not sign in' })
    return
  } finally {
    connecting = false
  }
  const username = first.username
  let pending: string | null = first.token
  setState({ username })

  xmpp = client({
    service: SERVICE,
    domain: DOMAIN,
    resource: 'webchat-' + newId().slice(0, 6),
    credentials: async (auth: any) => {
      const password = pending || (await requestToken()).token
      pending = null
      return auth({ username, password })
    },
  })

  xmpp.on('error', () => {})
  xmpp.on('offline', () => setState({ status: 'offline' }))
  xmpp.on('stanza', (stanza: any) => {
    if (stanza.is('presence')) return handlePresence(stanza)
    if (!stanza.is('message')) return
    const result = stanza.getChild('result', 'urn:xmpp:mam:2')
    if (result) {
      if (!stanza.attrs.from && result.attrs.queryid === archiveQuery) handleArchived(result)
      return
    }
    const carbon = stanza.getChild('received', 'urn:xmpp:carbons:2') || stanza.getChild('sent', 'urn:xmpp:carbons:2')
    if (carbon && bare(stanza.attrs.from) === `${username}@${DOMAIN}`) {
      const inner = carbon.getChild('forwarded', 'urn:xmpp:forward:0')?.getChild('message')
      if (inner) handleChat(inner, carbon.name === 'sent')
      return
    }
    if (stanza.attrs.type === 'groupchat') return handleGroupchat(stanza)
    if (stanza.attrs.type === 'chat' || stanza.attrs.type === 'normal' || !stanza.attrs.type) return handleChat(stanza)
  })
  xmpp.on('online', async () => {
    setState({ status: 'online', error: '' })
    const omemo = initOmemo(username, {
      get: (el: any, to?: string) => xmpp.iqCaller.get(el, to),
      set: (el: any, to?: string) => xmpp.iqCaller.set(el, to),
    }).catch(() => {})
    await xmpp.send(xml('presence'))
    xmpp.iqCaller.set(xml('enable', { xmlns: 'urn:xmpp:carbons:2' })).catch(() => {})
    for (const room of DEFAULT_ROOMS) joinRoom(room)
    omemo.then(loadHistory).catch(() => {})
  })

  try {
    await xmpp.start()
  } catch (e: any) {
    xmpp.stop().catch(() => {})
    xmpp = null
    setState({ status: 'offline', error: `Could not connect to the chat server${e?.message ? ` (${e.message})` : ''}` })
  }
}

export const PUBLIC_ROOMS = [`lobby@${MUC}`, `pl@${MUC}`]
export const isPublic = (jid: string) => PUBLIC_ROOMS.includes(jid)

// Public rooms
export function publicNick() {
  try {
    const saved = localStorage.getItem('public-nick')
    if (saved) return saved
    const nick = `guest${Math.floor(1000 + Math.random() * 9000)}`
    localStorage.setItem('public-nick', nick)
    return nick
  } catch {
    return 'guest'
  }
}

export function setPublicNick(nick: string) {
  try { localStorage.setItem('public-nick', nick) } catch {}
  for (const room of PUBLIC_ROOMS) {
    if (state.rooms[room]?.joined && xmpp) xmpp.send(xml('presence', { to: `${room}/${nick}` }))
    updateRoom(room, r => ({ ...r, nick }))
  }
}

export const roomNick = (room: string) => state.rooms[room]?.nick || (isPublic(room) ? publicNick() : state.username)

export function joinRoom(room: string) {
  if (!xmpp) return
  const known = state.rooms[room]?.messages.length || 0
  const nick = isPublic(room) ? publicNick() : state.username
  updateRoom(room, r => ({ ...r, nick, error: undefined }))
  xmpp.send(xml('presence', { to: `${room}/${nick}` },
    xml('x', { xmlns: 'http://jabber.org/protocol/muc' }, xml('history', { maxstanzas: known ? '0' : '50' }))))
}

export const omemoOn = (peer: string) => !isRoomJid(peer) && !state.omemoOff[peer]

export type Reply = { nick: string; id?: string; quote: string }

export async function sendMessage(to: string, text: string, oob?: string, reply?: Reply) {
  if (!xmpp || !text.trim()) return
  const isRoom = isRoomJid(to)
  const id = newId()
  const fallback = reply ? `> ${reply.nick}: ${reply.quote.replace(/\s+/g, ' ').slice(0, 80)}\n` : ''
  const body = fallback + text

  if (omemoOn(to)) {
    const encrypted = await encrypt(to, body)
    xmpp.send(xml('message', { to, type: 'chat', id },
      encrypted,
      xml('body', {}, 'This message is end-to-end encrypted with OMEMO. Open it in an app that supports OMEMO.'),
      xml('encryption', { xmlns: 'urn:xmpp:eme:0', namespace: OMEMO_NS, name: 'OMEMO' }),
      xml('store', { xmlns: 'urn:xmpp:hints' })))
    addDM(to, { id, from: state.username, body, ts: Date.now(), mine: true, secure: true })
    return
  }

  const children = [xml('body', {}, body)]
  if (reply?.id) {
    children.push(xml('reply', { xmlns: 'urn:xmpp:reply:0', id: reply.id, ...(isRoom ? { to: `${to}/${reply.nick}` } : {}) }))
    children.push(xml('fallback', { xmlns: 'urn:xmpp:fallback:0', for: 'urn:xmpp:reply:0' }, xml('body', { start: '0', end: String([...fallback].length) })))
  }
  if (oob) children.push(xml('x', { xmlns: 'jabber:x:oob' }, xml('url', {}, oob)))
  if (!isRoom) children.push(xml('active', { xmlns: 'http://jabber.org/protocol/chatstates' }))
  xmpp.send(xml('message', { to, type: isRoom ? 'groupchat' : 'chat', id }, ...children))
  if (!isRoom) addDM(to, { id, from: state.username, body, ts: Date.now(), mine: true })
}

export async function uploadFile(to: string, file: File) {
  if (!xmpp) throw new Error('Not connected')
  const sealed = omemoOn(to) ? await encryptFile(file) : null
  const body = sealed ? sealed.blob : file
  const type = sealed ? 'application/octet-stream' : file.type || 'application/octet-stream'
  const reply = await xmpp.iqCaller.request(xml('iq', { type: 'get', to: UPLOAD }, xml('request', {
    xmlns: 'urn:xmpp:http:upload:0', filename: file.name, size: String(body.size), 'content-type': type,
  })))
  const slot = reply.getChild('slot', 'urn:xmpp:http:upload:0')
  const put = slot?.getChild('put')?.attrs.url
  const get = slot?.getChild('get')?.attrs.url
  if (!put || !get) throw new Error('Upload slot was not granted')
  const resp = await fetch(put, { method: 'PUT', body, headers: { 'Content-Type': type } })
  if (!resp.ok) throw new Error('Upload failed')
  if (sealed) await sendMessage(to, get.replace(/^https:\/\//, 'aesgcm://') + '#' + sealed.fragment)
  else await sendMessage(to, get, get)
}

export async function moderate(room: string, stanzaId: string) {
  if (!xmpp) return
  await xmpp.iqCaller.set(xml('moderate', { xmlns: 'urn:xmpp:message-moderate:1', id: stanzaId },
    xml('retract', { xmlns: 'urn:xmpp:message-retract:1' })), room)
}

export async function getArchivePolicy(): Promise<ArchivePolicy> {
  if (!xmpp) return 'roster'
  const result = await xmpp.iqCaller.get(xml('prefs', { xmlns: 'urn:xmpp:mam:2' })).catch(() => null)
  return (result?.attrs.default as ArchivePolicy) || 'roster'
}

export async function setArchivePolicy(policy: ArchivePolicy) {
  if (!xmpp) return
  await xmpp.iqCaller.set(xml('prefs', { xmlns: 'urn:xmpp:mam:2', default: policy }, xml('always'), xml('never')))
}
