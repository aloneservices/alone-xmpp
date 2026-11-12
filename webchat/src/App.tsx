import { useEffect, useMemo, useRef, useState } from 'react'

import { notifyUnread, requestProfiles, type Plate, type Profile } from './bridge'
import {
  DEFAULT_ROOMS, DOMAIN, MUC, PUBLIC_ROOMS, connect, isPublic, isRoomJid, roomNick, setPublicNick, getArchivePolicy, joinRoom, moderate, sendMessage, setActive, setArchivePolicy, setOmemo,
  uploadFile, useChat, type ArchivePolicy, type ChatMessage, type Reply,
} from './xmpp/chat'
import { decryptFile, ownFingerprint, peerFingerprints } from './xmpp/omemo'

const DASHBOARD = import.meta.env.VITE_DASHBOARD_URL || 'https://alo.ne'
const URL_RE = /(https?:\/\/[^\s<>"]+)/g
const IMAGE_RE = /^https:\/\/upload\.alo\.ne\/(f|mb)\/[^\s]+\.(png|jpe?g|gif|webp)$/i
const ICONS: Record<string, string> = {
  star: '⭐', crown: '👑', gem: '💎', shield: '🛡', flame: '🔥', bolt: '⚡', heart: '❤', skull: '💀',
  moon: '🌙', sun: '☀', leaf: '🍃', spade: '♠', club: '♣', diamond: '♦', clover: '🍀', dice: '🎲',
}
const SKELETON = Array.from({ length: 8 }, (_, i) => 56 + (i % 3) * 12)
const RANKS = {
  admin: { label: 'Admin', colour: '#ef4444' },
  moderator: { label: 'Moderator', colour: '#a855f7' },
  reseller: { label: 'Reseller', colour: '#4ade80' },
  premium: { label: 'Premium', colour: '#60a5fa' },
}

function rankOf(profile?: Profile) {
  if (!profile) return null
  if (profile.staffType === 1) return RANKS.admin
  if (profile.staffType === 2) return RANKS.moderator
  if (profile.reseller) return RANKS.reseller
  if (profile.isPremium) return RANKS.premium
  return null
}

const short = (jid: string) => jid.split('@')[0]

const MENTION_RE = /(@[a-z0-9_.]{1,32})/gi

function Text({ text, me }: { text: string; me: string }) {
  return <>{text.split(MENTION_RE).map((part, i) => i % 2 === 0
    ? part
    : <span key={i} className={`mention ${part.slice(1).toLowerCase() === me ? 'me' : ''}`}>{part}</span>)}</>
}

function splitQuote(body: string) {
  const match = body.match(/^((?:(?:> ?|↪ )[^\n]*\n)+)([\s\S]*)$/)
  if (!match || !match[2].trim()) return { quote: '', rest: body }
  return { quote: match[1].split('\n').map(line => line.replace(/^(?:> ?|↪ )/, '')).filter(Boolean).join(' '), rest: match[2] }
}

function Body({ text, me = '' }: { text: string; me?: string }) {
  const parts = text.split(URL_RE)
  return (
    <span className="body">
      {parts.map((part, i) => {
        if (i % 2 === 0) return <Text key={i} text={part} me={me} />
        if (IMAGE_RE.test(part)) return <a key={i} href={part} target="_blank" rel="noopener noreferrer"><img src={part} alt="" className="preview" loading="lazy" /></a>
        return <a key={i} href={part} target="_blank" rel="noopener noreferrer nofollow">{part}</a>
      })}
    </span>
  )
}

function PlateTag({ plate }: { plate: Plate }) {
  return (
    <span className="plate" style={{ color: plate.fg, background: plate.bg, borderColor: plate.border || plate.bg }}>
      {plate.icon && ICONS[plate.icon] ? `${ICONS[plate.icon]} ` : ''}{plate.text}
    </span>
  )
}

function Name({ username, profile }: { username: string; profile?: Profile }) {
  const rank = rankOf(profile)
  return (
    <span className="name">
      <b style={{ color: profile?.chatColour || rank?.colour || 'var(--text)' }}>{username}</b>
      {rank && <span className="rank" style={{ color: rank.colour }}>{rank.label}</span>}
      {profile?.nameplate && <PlateTag plate={profile.nameplate} />}
    </span>
  )
}

function EncryptedFile({ url, onError }: { url: string; onError: (text: string) => void }) {
  const [view, setView] = useState<{ src?: string; busy?: boolean }>({})
  const name = decodeURIComponent(url.split('#')[0].split('/').pop() || 'file')
  const image = /\.(png|jpe?g|gif|webp)$/i.test(name)
  const open = async () => {
    setView({ busy: true })
    try {
      const blob = await decryptFile(url)
      const src = URL.createObjectURL(image ? new Blob([blob], { type: `image/${name.split('.').pop()!.replace('jpg', 'jpeg')}` }) : blob)
      setView({ src })
      if (!image) {
        const a = document.createElement('a')
        a.href = src
        a.download = name
        a.click()
      }
    } catch {
      onError('Could not decrypt the file')
      setView({})
    }
  }
  if (view.src && image) return <img src={view.src} alt="" className="preview" />
  return <button className="file" onClick={open} disabled={view.busy}>{view.busy ? '…' : '🔒'} {name}</button>
}

function Message({ message, profile, me, canModerate, onDelete, onError, onReply, onMention }: {
  message: ChatMessage; profile?: Profile; me: string; canModerate: boolean; onDelete: () => void; onError: (text: string) => void
  onReply: (reply: Reply) => void; onMention: (name: string) => void
}) {
  const time = new Date(message.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  const relayed = message.from === 'bridge' ? message.body.match(/^([^:\n]{1,80}): ([\s\S]*)$/) : null
  const author = relayed ? relayed[1] : message.from
  const { quote, rest } = splitQuote(relayed ? relayed[2] : message.body)
  const mentioned = !message.mine && new RegExp(`@${me}\\b`, 'i').test(rest)
  const name = <button className="who" title={`Mention ${author}`} onClick={() => onMention(author.split(' ')[0])}>
    {relayed ? <span className="muted strong">{author}</span> : <Name username={message.from} profile={profile} />}
  </button>

  let content
  if (message.encrypted) content = <>{name} <span className="muted">🔒 Encrypted message, open it in an app with OMEMO</span></>
  else if (rest.startsWith('/me ')) content = <i>* {name} <Body text={rest.slice(4)} me={me} /></i>
  else content = (
    <>
      {name} {message.secure && <span className="lock">🔒</span>}
      {message.secure && rest.startsWith('aesgcm://') ? <EncryptedFile url={rest} onError={onError} /> : <Body text={rest} me={me} />}
    </>
  )
  return (
    <div className={`message ${mentioned ? 'mentioned' : ''}`}>
      <span className="time">{time}</span>
      <div className="content">
        {quote && <div className="quote">↪ {quote}</div>}
        {content}
      </div>
      {!message.encrypted && <button className="act" title="Reply" onClick={() => onReply({ nick: author, id: message.stanzaId || message.id, quote: rest })}>↩</button>}
      {canModerate && message.stanzaId && <button className="act delete" title="Delete message" onClick={onDelete}>✕</button>}
    </div>
  )
}

export default function App() {
  const { status, error, username, rooms, dms, unread, active, omemoOff } = useChat()
  const [draft, setDraft] = useState('')
  const [replyTo, setReplyTo] = useState<Reply | null>(null)
  const composer = useRef<HTMLTextAreaElement>(null)
  const [newDM, setNewDM] = useState('')
  const [notice, setNotice] = useState('')
  const [uploading, setUploading] = useState(false)
  const [policy, setPolicy] = useState<ArchivePolicy | null>(null)
  const [profiles, setProfiles] = useState<Record<string, Profile>>({})
  const [fingerprints, setFingerprints] = useState<{ own: string; peer: { id: number; fingerprint: string }[] } | null>(null)
  const requested = useRef(new Set<string>())
  const bottom = useRef<HTMLDivElement>(null)
  const fileInput = useRef<HTMLInputElement>(null)

  const flash = (text: string) => { setNotice(text); setTimeout(() => setNotice(''), 6000) }

  useEffect(() => { connect() }, [])
  useEffect(() => { if (status === 'online') getArchivePolicy().then(setPolicy) }, [status])
  useEffect(() => { setFingerprints(null) }, [active])
  useEffect(() => { notifyUnread(Object.values(unread).reduce((a, b) => a + b, 0)) }, [unread])

  const isRoom = isRoomJid(active)
  const room = rooms[active]
  const messages = isRoom ? room?.messages || [] : dms[active] || []
  const occupants = useMemo(() => Object.values(room?.occupants || {}).sort((a, b) => a.nick.localeCompare(b.nick)), [room])

  const recentNames = useMemo(() => {
    const names: string[] = []
    for (let i = messages.length - 1; i >= 0 && names.length < 50; i--) {
      const m = messages[i]
      const name = m.from === 'bridge' ? m.body.match(/^([^:\n\s]{1,40})[^:\n]*: /)?.[1] : m.from
      if (name && name !== username && !names.some(n => n.toLowerCase() === name.toLowerCase())) names.push(name)
    }
    return names
  }, [messages, username])

  const typed = draft.match(/(?:^|\s)@([a-z0-9_.]{1,32})$/i)?.[1] || ''
  const completion = typed ? recentNames.find(n => n.toLowerCase().startsWith(typed.toLowerCase()) && n.length > typed.length) : undefined
  const ghost = completion ? completion.slice(typed.length) + ' ' : ''
  const publicRoom = isPublic(active)
  const canModerate = isRoom && room?.occupants[roomNick(active)]?.role === 'moderator'
  const encrypted = !isRoom && !omemoOff[active]

  useEffect(() => {
    if (publicRoom) return
    const names = new Set<string>([...messages.map(m => m.from), ...occupants.map(o => o.nick)])
    const missing = [...names].filter(n => /^[a-z0-9]+$/.test(n) && !requested.current.has(n)).slice(0, 100)
    if (missing.length === 0) return
    missing.forEach(n => requested.current.add(n))
    requestProfiles(missing).then(found => setProfiles(p => ({ ...p, ...found })))
  }, [messages, occupants, publicRoom])

  useEffect(() => { bottom.current?.scrollIntoView({ block: 'end' }) }, [messages.length, active])

  const send = () => {
    const text = draft.trim()
    if (!text) return
    if (text.startsWith('/nick ')) {
      const nick = text.slice(6).trim()
      if (publicRoom && /^[\p{L}\p{N}_.-]{1,32}$/u.test(nick)) setPublicNick(nick)
      else flash(publicRoom ? 'Nicks can use letters, numbers, dots, dashes and underscores' : 'You can only change your nick in public rooms')
    } else if (text.startsWith('/join ')) {
      const name = text.slice(6).replace(/^#/, '').trim().toLowerCase()
      const room = name.includes('@') ? name : `${name}@${MUC}`
      if (/^[a-z0-9_.-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(room)) { joinRoom(room); setActive(room) }
      else flash('Use /join room or /join room@server')
    } else if (text.startsWith('/pm ')) {
      const match = text.match(/^\/pm @?([a-z0-9]+) ([\s\S]+)$/)
      if (match) {
        sendMessage(`${match[1]}@${DOMAIN}`, match[2]).catch((e: any) => flash(e?.message || 'Could not send'))
        setActive(`${match[1]}@${DOMAIN}`)
      } else flash('Use /pm @user message')
    } else {
      sendMessage(active, text, undefined, replyTo || undefined).catch((e: any) => flash(`${e?.message || 'Could not encrypt'}. Turn off encryption for this chat to send it unencrypted.`))
    }
    setDraft('')
    setReplyTo(null)
  }

  const mention = (name: string) => {
    setDraft(d => `${d}${d && !d.endsWith(' ') ? ' ' : ''}@${name} `)
    composer.current?.focus()
  }

  const upload = async (file: File) => {
    setUploading(true)
    try { await uploadFile(active, file) } catch (e: any) { flash(e?.message || 'Upload failed') }
    setUploading(false)
    if (fileInput.current) fileInput.current.value = ''
  }

  const changePolicy = async (value: ArchivePolicy) => {
    try { await setArchivePolicy(value); setPolicy(value); flash('DM storage updated') } catch { flash('Could not update DM storage') }
  }

  const openDM = () => {
    const name = newDM.trim().toLowerCase().replace(/^@/, '')
    if (!/^[a-z0-9]+$/.test(name)) return
    setActive(`${name}@${DOMAIN}`)
    setNewDM('')
  }

  const showFingerprints = async () => {
    if (fingerprints) { setFingerprints(null); return }
    setFingerprints({ own: ownFingerprint(), peer: await peerFingerprints(active) })
  }

  const roomList = Array.from(new Set([...DEFAULT_ROOMS, ...Object.keys(rooms)])).filter(jid => !isPublic(jid))
  const open = (jid: string) => {
    setActive(jid)
    if (isPublic(jid) && !rooms[jid]?.joined) joinRoom(jid)
  }
  const item = (jid: string, label: string) => (
    <button key={jid} className={`item ${active === jid ? 'active' : ''}`} onClick={() => open(jid)}>
      <span>{label}</span>
      {!!unread[jid] && <span className="badge">{unread[jid]}</span>}
    </button>
  )

  const loading = status !== 'online' || (isRoom && !room?.joined && !room?.error && messages.length === 0)

  if (status === 'offline' && error) {
    return <div className="center"><p>{error}</p><button className="primary" onClick={() => connect()}>Try again</button></div>
  }

  return (
    <div className="chat">
      <aside className="side">
        <p className="label">Channels</p>
        {roomList.map(jid => item(jid, `${jid === `premium@${MUC}` ? '🔒' : '#'} ${jid.endsWith(MUC) ? short(jid) : jid}`))}
        <p className="label">Public</p>
        {PUBLIC_ROOMS.map(jid => item(jid, `# ${short(jid)}`))}
        <p className="label">Direct messages</p>
        {Object.keys(dms).map(jid => item(jid, `@ ${short(jid)}`))}
        <input value={newDM} onChange={e => setNewDM(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') openDM() }} placeholder="Message a user" />
        <div className="spacer" />
        <label className="label">Keep my DMs on the server</label>
        <select value={policy || 'roster'} disabled={status !== 'online' || !policy} onChange={e => changePolicy(e.target.value as ArchivePolicy)}>
          <option value="roster">Contacts only, 1 day</option>
          <option value="always">Everyone, 1 day</option>
          <option value="never">Never</option>
        </select>
      </aside>

      <section className="main">
        <header className="head">
          <b>{isRoom ? '#' : '@'} {short(active)}</b>
          <span className="head-right">
            {!isRoom && <button className="link" onClick={showFingerprints}>Fingerprints</button>}
            {!isRoom && <button className={`link ${encrypted ? 'on' : 'off'}`} onClick={() => setOmemo(active, !encrypted)}>{encrypted ? '🔒 Encrypted' : '🔓 Not encrypted'}</button>}
          </span>
        </header>
        {fingerprints && (
          <div className="fingerprints">
            <p>Compare these with the fingerprints in the other person's app. If they match, nobody is in the middle.</p>
            <p>This browser: <code>{fingerprints.own || 'Not set up yet'}</code></p>
            {fingerprints.peer.length === 0 && <p>{short(active)} has no OMEMO devices yet.</p>}
            {fingerprints.peer.map(d => <p key={d.id}>{short(active)} device {d.id}: <code>{d.fingerprint}</code></p>)}
          </div>
        )}
        {notice && <div className="notice">{notice}</div>}

        <div className="messages">
          {isRoom && room?.error && (
            <p className="note">
              {room.error}{' '}
              {active === `premium@${MUC}` && <a href={`${DASHBOARD}/dashboard/order`} target="_top">Get premium</a>}
            </p>
          )}
          {publicRoom && (
            <p className="note">
              Public room, open to anyone on any server and shared with #{short(active)} on irc.alo.ne. You show as{' '}
              <b>{roomNick(active)}</b> here, not your account name. Type /nick name to change it.
            </p>
          )}
          {!isRoom && (
            <p className="note">
              {encrypted
                ? 'End-to-end encrypted with OMEMO. Keys live in this browser, so clearing site data makes it a new device. For the strongest protection, use an app.'
                : 'Encryption is off for this chat. Messages and files are readable by the server.'}
            </p>
          )}
          {loading && SKELETON.map((width, i) => (
            <div key={i} className="skeleton" style={{ animationDelay: `${i * 70}ms` }}>
              <span style={{ width: 38 }} /><span style={{ width }} /><span className="fill" />
            </div>
          ))}
          {!loading && messages.map(message => (
            <Message
              key={message.id + message.from}
              message={message}
              profile={publicRoom ? undefined : profiles[message.from]}
              me={isRoom ? roomNick(active) : username}
              canModerate={canModerate}
              onError={flash}
              onReply={reply => { setReplyTo(reply); composer.current?.focus() }}
              onMention={mention}
              onDelete={() => message.stanzaId && moderate(active, message.stanzaId).catch(() => flash('Could not delete message'))}
            />
          ))}
          <div ref={bottom} />
        </div>

        {!loading && replyTo && (
          <div className="replying">
            <span>Replying to <b>{replyTo.nick}</b>: {replyTo.quote.slice(0, 80)}</span>
            <button title="Cancel reply" onClick={() => setReplyTo(null)}>✕</button>
          </div>
        )}
        {!loading && <footer className="composer">
          <input ref={fileInput} type="file" hidden onChange={e => e.target.files?.[0] && upload(e.target.files[0])} />
          <button className="icon" title="Upload a file" disabled={status !== 'online' || uploading} onClick={() => fileInput.current?.click()}>{uploading ? '…' : '📎'}</button>
          <div className="input-wrap">
          <div className="ghost" aria-hidden="true"><span>{draft}</span>{ghost}</div>
          <textarea
            ref={composer}
            value={draft}
            onChange={e => setDraft(e.target.value)}
            onKeyDown={e => {
              if (e.key === 'Tab' && ghost) { e.preventDefault(); setDraft(d => d + ghost) }
              if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
              if (e.key === 'Escape') setReplyTo(null)
            }}
            rows={1}
            maxLength={4000}
            disabled={status !== 'online'}
            placeholder={status === 'online' ? `Message ${isRoom ? '#' : '@'}${short(active)}` : 'Connecting'}
          />
          </div>
          <button className="primary" disabled={status !== 'online' || !draft.trim()} onClick={send}>Send</button>
        </footer>}
      </section>

      {isRoom && (
        <aside className="members">
          <p className="label">Members · {occupants.length}</p>
          {occupants.map(o => (
            <button key={o.nick} className="item" onClick={() => !publicRoom && o.nick !== username && o.nick !== 'bridge' && setActive(`${o.nick}@${DOMAIN}`)}>
              <Name username={o.nick} profile={publicRoom ? undefined : profiles[o.nick]} />
            </button>
          ))}
        </aside>
      )}
    </div>
  )
}
