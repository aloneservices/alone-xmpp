import { xml } from '@xmpp/client'
import {
  KeyHelper, SessionBuilder, SessionCipher, SignalProtocolAddress,
  type Direction, type KeyPairType, type StorageType,
} from '@privacyresearch/libsignal-protocol-typescript'

export const NS = 'eu.siacs.conversations.axolotl'
const DEVICELIST = `${NS}.devicelist`
const BUNDLES = `${NS}.bundles:`
const PREKEY_COUNT = 100

type Transport = { get: (el: any, to?: string) => Promise<any>; set: (el: any, to?: string) => Promise<any> }

let transport: Transport | null = null
let me = ''
let deviceId = 0
let ready: Promise<void> | null = null
const deviceCache = new Map<string, { ids: number[]; at: number }>()

const toB64 = (buf: ArrayBuffer | Uint8Array) => {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf)
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s)
}
const fromB64 = (s: string) => Uint8Array.from(atob(s.trim()), c => c.charCodeAt(0))
const ab = (u: Uint8Array) => u.buffer.slice(u.byteOffset, u.byteOffset + u.byteLength) as ArrayBuffer
const toHex = (u: Uint8Array) => Array.from(u, b => b.toString(16).padStart(2, '0')).join('')
const fromHex = (s: string) => Uint8Array.from(s.match(/.{2}/g) || [], h => parseInt(h, 16))

const key = (name: string) => `omemo:${me}:${name}`
const read = (name: string) => { try { return localStorage.getItem(key(name)) } catch { return null } }
const write = (name: string, value: string) => { try { localStorage.setItem(key(name), value) } catch {} }
const remove = (name: string) => { try { localStorage.removeItem(key(name)) } catch {} }
const readPair = (name: string): KeyPairType | undefined => {
  const raw = read(name)
  if (!raw) return undefined
  const { pub, priv } = JSON.parse(raw)
  return { pubKey: ab(fromB64(pub)), privKey: ab(fromB64(priv)) }
}
const writePair = (name: string, pair: KeyPairType) => write(name, JSON.stringify({ pub: toB64(pair.pubKey), priv: toB64(pair.privKey) }))

const store: StorageType = {
  getIdentityKeyPair: async () => readPair('identity'),
  getLocalRegistrationId: async () => Number(read('registration')) || undefined,
  isTrustedIdentity: async (_id: string, _key: ArrayBuffer, _direction: Direction) => true,
  saveIdentity: async (address: string, publicKey: ArrayBuffer) => {
    const encoded = toB64(publicKey)
    const changed = read(`identity:${address}`) !== encoded
    write(`identity:${address}`, encoded)
    return changed
  },
  loadPreKey: async id => readPair(`prekey:${id}`),
  storePreKey: async (id, pair) => writePair(`prekey:${id}`, pair),
  removePreKey: async id => { remove(`prekey:${id}`); scheduleRefill() },
  storeSession: async (address, record) => write(`session:${address}`, record),
  loadSession: async address => read(`session:${address}`) || undefined,
  loadSignedPreKey: async id => readPair(`signed:${id}`),
  storeSignedPreKey: async (id, pair) => writePair(`signed:${id}`, pair),
  removeSignedPreKey: async id => remove(`signed:${id}`),
}

function publishOptions() {
  return xml('publish-options', {},
    xml('x', { xmlns: 'jabber:x:data', type: 'submit' },
      xml('field', { var: 'FORM_TYPE', type: 'hidden' }, xml('value', {}, 'http://jabber.org/protocol/pubsub#publish-options')),
      xml('field', { var: 'pubsub#access_model' }, xml('value', {}, 'open'))))
}

async function publish(node: string, payload: any) {
  await transport!.set(xml('pubsub', { xmlns: 'http://jabber.org/protocol/pubsub' },
    xml('publish', { node }, xml('item', { id: 'current' }, payload)), publishOptions()))
}

async function preKeyIds(): Promise<number[]> {
  return JSON.parse(read('prekeys') || '[]')
}

async function publishBundle() {
  const identity = (await store.getIdentityKeyPair())!
  const signed = readPair('signed:1')!
  const ids = await preKeyIds()
  const prekeys = []
  for (const id of ids) {
    const pair = readPair(`prekey:${id}`)
    if (pair) prekeys.push(xml('preKeyPublic', { preKeyId: String(id) }, toB64(pair.pubKey)))
  }
  await publish(BUNDLES + deviceId, xml('bundle', { xmlns: NS },
    xml('signedPreKeyPublic', { signedPreKeyId: '1' }, toB64(signed.pubKey)),
    xml('signedPreKeySignature', {}, read('signed:1:signature') || ''),
    xml('identityKey', {}, toB64(identity.pubKey)),
    xml('prekeys', {}, ...prekeys)))
}

let refillTimer: ReturnType<typeof setTimeout> | null = null
function scheduleRefill() {
  if (refillTimer) return
  refillTimer = setTimeout(async () => {
    refillTimer = null
    const ids = (await preKeyIds()).filter(id => read(`prekey:${id}`))
    let next = Number(read('prekey-next')) || PREKEY_COUNT + 1
    while (ids.length < PREKEY_COUNT) {
      const pre = await KeyHelper.generatePreKey(next)
      await store.storePreKey(pre.keyId, pre.keyPair)
      ids.push(next++)
    }
    write('prekeys', JSON.stringify(ids))
    write('prekey-next', String(next))
    publishBundle().catch(() => {})
  }, 2000)
}

export async function deviceList(jid: string, fresh = false): Promise<number[]> {
  const cached = deviceCache.get(jid)
  if (!fresh && cached && Date.now() - cached.at < 5 * 60_000) return cached.ids
  const result = await transport!.get(xml('pubsub', { xmlns: 'http://jabber.org/protocol/pubsub' }, xml('items', { node: DEVICELIST })), jid).catch(() => null)
  const list = result?.getChild('items')?.getChild('item')?.getChild('list', NS)
  const ids = list ? list.getChildren('device').map((d: any) => Number(d.attrs.id)).filter((id: number) => id > 0) : []
  deviceCache.set(jid, { ids, at: Date.now() })
  return ids
}

async function setup(username: string, t: Transport) {
  transport = t
  me = username
  deviceId = Number(read('device')) || 0
  if (!deviceId || !read('identity')) {
    deviceId = 1 + Math.floor(Math.random() * 0x7ffffffe)
    write('device', String(deviceId))
    write('registration', String(KeyHelper.generateRegistrationId()))
    writePair('identity', await KeyHelper.generateIdentityKeyPair())
    const signed = await KeyHelper.generateSignedPreKey((await store.getIdentityKeyPair())!, 1)
    await store.storeSignedPreKey(1, signed.keyPair)
    write('signed:1:signature', toB64(signed.signature))
    const ids = []
    for (let id = 1; id <= PREKEY_COUNT; id++) {
      const pre = await KeyHelper.generatePreKey(id)
      await store.storePreKey(pre.keyId, pre.keyPair)
      ids.push(id)
    }
    write('prekeys', JSON.stringify(ids))
    write('prekey-next', String(PREKEY_COUNT + 1))
  }

  await publishBundle()
  const own = await deviceList(`${me}@alo.ne`, true)
  if (!own.includes(deviceId)) {
    const ids = [...own, deviceId]
    await publish(DEVICELIST, xml('list', { xmlns: NS }, ...ids.map(id => xml('device', { id: String(id) }))))
    deviceCache.set(`${me}@alo.ne`, { ids, at: Date.now() })
  }
}

export function initOmemo(username: string, t: Transport) {
  ready = setup(username, t)
  return ready
}

async function ensureSession(jid: string, id: number): Promise<boolean> {
  const address = new SignalProtocolAddress(jid, id)
  if (await store.loadSession(address.toString())) return true
  const result = await transport!.get(xml('pubsub', { xmlns: 'http://jabber.org/protocol/pubsub' }, xml('items', { node: BUNDLES + id })), jid).catch(() => null)
  const bundle = result?.getChild('items')?.getChild('item')?.getChild('bundle', NS)
  if (!bundle) return false
  const prekeys = bundle.getChild('prekeys')?.getChildren('preKeyPublic') || []
  if (prekeys.length === 0) return false
  const pre = prekeys[Math.floor(Math.random() * prekeys.length)]
  const signed = bundle.getChild('signedPreKeyPublic')
  await new SessionBuilder(store, address).processPreKey({
    identityKey: ab(fromB64(bundle.getChildText('identityKey'))),
    signedPreKey: {
      keyId: Number(signed.attrs.signedPreKeyId),
      publicKey: ab(fromB64(signed.text())),
      signature: ab(fromB64(bundle.getChildText('signedPreKeySignature'))),
    },
    preKey: { keyId: Number(pre.attrs.preKeyId), publicKey: ab(fromB64(pre.text())) },
  })
  return true
}

export async function canEncrypt(peer: string) {
  if (!ready) return false
  await ready.catch(() => {})
  return (await deviceList(peer).catch(() => [])).length > 0
}

export async function encrypt(peer: string, plaintext: string) {
  if (!ready) throw new Error('Encryption is not ready')
  await ready
  const ownJid = `${me}@alo.ne`
  const targets: [string, number][] = []
  for (const id of await deviceList(peer, true)) targets.push([peer, id])
  for (const id of await deviceList(ownJid)) if (id !== deviceId) targets.push([ownJid, id])

  const messageKey = crypto.getRandomValues(new Uint8Array(16))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const cryptoKey = await crypto.subtle.importKey('raw', messageKey, 'AES-GCM', false, ['encrypt'])
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, cryptoKey, new TextEncoder().encode(plaintext)))
  const payload = sealed.slice(0, -16)
  const material = new Uint8Array(32)
  material.set(messageKey)
  material.set(sealed.slice(-16), 16)

  const keys = []
  let peerKeys = 0
  for (const [jid, id] of targets) {
    try {
      if (!(await ensureSession(jid, id))) continue
      const result = await new SessionCipher(store, new SignalProtocolAddress(jid, id)).encrypt(ab(material))
      keys.push(xml('key', { rid: String(id), ...(result.type === 3 ? { prekey: 'true' } : {}) }, btoa(result.body || '')))
      if (jid === peer) peerKeys++
    } catch {}
  }
  if (peerKeys === 0) throw new Error(`${peer.split('@')[0]} has no OMEMO devices this chat can reach`)

  return xml('encrypted', { xmlns: NS },
    xml('header', { sid: String(deviceId) }, ...keys, xml('iv', {}, toB64(iv))),
    xml('payload', {}, toB64(payload)))
}

export async function decrypt(sender: string, encrypted: any): Promise<string | null> {
  if (!ready) return null
  await ready.catch(() => {})
  const header = encrypted.getChild('header')
  const ownKey = header?.getChildren('key').find((k: any) => Number(k.attrs.rid) === deviceId)
  if (!ownKey) return null

  const cipher = new SessionCipher(store, new SignalProtocolAddress(sender, Number(header.attrs.sid)))
  const binary = atob(ownKey.text().trim())
  const prekey = ownKey.attrs.prekey === 'true' || ownKey.attrs.prekey === '1'
  const material = new Uint8Array(prekey ? await cipher.decryptPreKeyWhisperMessage(binary, 'binary') : await cipher.decryptWhisperMessage(binary, 'binary'))

  const payloadText = encrypted.getChildText('payload')
  if (!payloadText) return ''
  const iv = fromB64(header.getChildText('iv'))
  let sealed = fromB64(payloadText)
  if (material.length >= 32) {
    const joined = new Uint8Array(sealed.length + 16)
    joined.set(sealed)
    joined.set(material.slice(16, 32), sealed.length)
    sealed = joined
  }
  const cryptoKey = await crypto.subtle.importKey('raw', material.slice(0, 16), 'AES-GCM', false, ['decrypt'])
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, cryptoKey, sealed))
}

function fingerprint(publicKey: Uint8Array) {
  const hex = toHex(publicKey.length === 33 ? publicKey.slice(1) : publicKey)
  return hex.match(/.{8}/g)!.join(' ')
}

export function ownFingerprint() {
  const raw = read('identity')
  return raw ? fingerprint(fromB64(JSON.parse(raw).pub)) : ''
}

export async function peerFingerprints(peer: string) {
  const ids = await deviceList(peer).catch(() => [] as number[])
  return ids.map(id => {
    const raw = read(`identity:${peer}.${id}`)
    return { id, fingerprint: raw ? fingerprint(fromB64(raw)) : 'Not seen yet' }
  })
}

// File encryption
export async function encryptFile(file: File) {
  const fileKey = crypto.getRandomValues(new Uint8Array(32))
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const cryptoKey = await crypto.subtle.importKey('raw', fileKey, 'AES-GCM', false, ['encrypt'])
  const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, cryptoKey, await file.arrayBuffer())
  return { blob: new Blob([sealed], { type: 'application/octet-stream' }), fragment: toHex(iv) + toHex(fileKey) }
}

export async function decryptFile(aesgcmUrl: string) {
  const [location, fragment] = aesgcmUrl.split('#')
  const bytes = fromHex(fragment || '')
  const ivLength = bytes.length === 48 ? 16 : 12
  const iv = bytes.slice(0, ivLength)
  const fileKey = bytes.slice(ivLength)
  const resp = await fetch(location.replace(/^aesgcm:\/\//, 'https://'))
  if (!resp.ok) throw new Error('File not found')
  const cryptoKey = await crypto.subtle.importKey('raw', fileKey, 'AES-GCM', false, ['decrypt'])
  return new Blob([await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, cryptoKey, await resp.arrayBuffer())])
}
