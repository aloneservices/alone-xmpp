export type Plate = { text: string; fg: string; bg: string; border?: string | null; icon?: string | null }

export type Profile = {
  nid: number
  staffType: number
  isPremium: boolean
  reseller: boolean
  biolinkUsername: string | null
  nameplate?: Plate
  chatColour?: string
}

const ORIGINS = (import.meta.env.VITE_PARENT_ORIGINS || 'https://alo.ne').split(',').map((o: string) => o.trim())
const host: Window | null = window.parent !== window ? window.parent : window.opener
if (window.parent !== window) document.documentElement.classList.add('framed')

let tokenWaiters: ((value: { token: string; username: string }) => void)[] = []
const profileWaiters = new Map<string, (profiles: Record<string, Profile>) => void>()

window.addEventListener('message', event => {
  if (!ORIGINS.includes(event.origin) || event.source !== host) return
  const data = event.data
  if (data?.type === 'alone-chat:token' && typeof data.token === 'string' && /^[a-z0-9]+$/.test(data.username)) {
    tokenWaiters.forEach(resolve => resolve({ token: data.token, username: data.username }))
    tokenWaiters = []
  }
  if (data?.type === 'alone-chat:theme' && (data.theme === 'light' || data.theme === 'dark')) {
    document.documentElement.dataset.theme = data.theme
  }
  if (data?.type === 'alone-chat:profiles' && typeof data.id === 'string') {
    profileWaiters.get(data.id)?.(data.profiles || {})
    profileWaiters.delete(data.id)
  }
})

function post(message: object) {
  for (const origin of ORIGINS) host?.postMessage(message, origin)
}

export const hasHost = !!host
post({ type: 'alone-chat:theme' })

export function requestToken(): Promise<{ token: string; username: string }> {
  return new Promise((resolve, reject) => {
    if (!host) return reject(new Error('Open the chat from your alo.ne dashboard'))
    let tries = 0
    const ask = setInterval(() => {
      if (++tries > 15) {
        clearInterval(ask)
        reject(new Error('The dashboard did not answer, refresh it and try again'))
        return
      }
      post({ type: 'alone-chat:token' })
    }, 1000)
    tokenWaiters.push(value => { clearInterval(ask); resolve(value) })
    post({ type: 'alone-chat:token' })
  })
}

export function requestProfiles(users: string[]): Promise<Record<string, Profile>> {
  return new Promise(resolve => {
    if (!host || users.length === 0) return resolve({})
    const id = Math.random().toString(36).slice(2)
    profileWaiters.set(id, resolve)
    post({ type: 'alone-chat:profiles', id, users })
    setTimeout(() => { profileWaiters.delete(id); resolve({}) }, 10000)
  })
}

export function notifyUnread(count: number) {
  post({ type: 'alone-chat:unread', count })
}
