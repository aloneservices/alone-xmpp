const HASHES = 'https://raw.githubusercontent.com/aloneservices/alone-hashes/main'

const DASHBOARD_DOMAINS = ['alo.ne', 'afra.id', 'ra.pe', 'e.rip', 'sexu.al', 'deni.al', 'karamb.it', 'trapst.ar', 'drugabu.se']

const SOURCES = [
  { name: 'Webchat (chat.alo.ne)', list: `${HASHES}/webchat.txt.asc`, base: 'https://chat.alo.ne/web' },
  { name: 'Dashboard', list: `${HASHES}/dashboard.txt.asc`, base: 'https://alo.ne', pages: ['/', '/login', '/dashboard'], domains: DASHBOARD_DOMAINS },
]

const LINE = /^([0-9a-f]{64}) {2}(\/\S+)$/gm

const RESULTS = { ok: ['OK', 'ok'], changed: ['CHANGED', 'bad'], missing: ['Not found', 'bad'], error: ['Error', 'bad'], unsigned: ['NOT SIGNED', 'bad'] }

const el = (tag, props = {}) => Object.assign(document.createElement(tag), props)

const sha256 = async buffer => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', buffer)), b => b.toString(16).padStart(2, '0')).join('')

async function check(url, expected) {
  try {
    const resp = await fetch(url, { cache: 'no-store', credentials: 'omit' })
    if (!resp.ok) return resp.status === 404 ? 'missing' : 'error'
    return await sha256(await resp.arrayBuffer()) === expected ? 'ok' : 'changed'
  } catch {
    return 'error'
  }
}

async function pageScripts(origin, pages) {
  const scripts = new Set()
  for (const page of pages) {
    const html = await fetch(origin + page, { cache: 'no-store', credentials: 'omit' }).then(r => r.ok ? r.text() : null).catch(() => null)
    if (html === null) {
      scripts.add(`unreadable:${origin}${page}`)
      continue
    }
    const doc = new DOMParser().parseFromString(html, 'text/html')
    for (const node of doc.querySelectorAll('script[src], link[rel="modulepreload"][href], link[rel="preload"][as="script"][href]')) {
      scripts.add(new URL(node.getAttribute('src') || node.getAttribute('href'), origin + page).href)
    }
  }
  return scripts
}

async function checkAll(jobs, table) {
  let bad = 0
  await Promise.all(Array.from({ length: 6 }, async () => {
    for (let job; (job = jobs.shift());) {
      const state = el('td', { className: 'state', textContent: '…' })
      const row = el('tr')
      row.append(state, el('td', { textContent: job.label }))
      table.append(row)
      const [label, tone] = RESULTS[job.hash ? await check(job.url, job.hash) : job.result]
      Object.assign(state, { textContent: label, className: `state ${tone}` })
      if (tone === 'bad') bad++
    }
  }))
  return bad
}

async function run(source, container) {
  const status = el('p', { className: 'muted', textContent: 'Downloading the signed list from GitHub…' })
  const table = el('table', { className: 'results' })
  const section = el('section')
  section.append(el('h3', { textContent: source.name }), status, table)
  container.append(section)

  const text = await fetch(source.list, { cache: 'no-store' }).then(r => r.ok ? r.text() : null).catch(() => null)
  if (text === null) {
    Object.assign(status, { className: 'bad', textContent: 'Could not download the signed list from GitHub.' })
    return 1
  }

  const entries = [...text.matchAll(LINE)].map(([, hash, path]) => ({ hash, path }))
  const signed = new Map(entries.map(e => [e.path, e.hash]))
  status.textContent = `${entries.length} files in the signed list. `
  status.append(el('a', { href: source.list, target: '_blank', rel: 'noopener', textContent: 'View the signed list' }))

  let bad = await checkAll(entries.map(e => ({ label: e.path, url: source.base + e.path, hash: e.hash })), table)

  for (const domain of source.domains || []) {
    const origin = `https://${domain}`
    const jobs = [...await pageScripts(origin, source.pages)].map(url => {
      if (url.startsWith('unreadable:')) return { label: `${url.slice(11)} (page could not be read)`, result: 'error' }
      const { origin: from, pathname } = new URL(url)
      const hash = from === origin && signed.get(pathname)
      return hash ? { label: `${domain} ${pathname}`, url, hash } : { label: `${domain} ${url}`, result: 'unsigned' }
    })
    bad += await checkAll(jobs, table)
  }
  return bad
}

const button = document.getElementById('run')
const summary = document.getElementById('summary')
const results = document.getElementById('results')

button.hidden = false
button.addEventListener('click', async () => {
  button.disabled = true
  results.textContent = ''
  Object.assign(summary, { className: 'muted', textContent: 'Checking…' })

  let bad = 0
  for (const source of SOURCES) bad += await run(source, results)

  Object.assign(summary, bad === 0
    ? { className: 'ok', textContent: 'Every file matches the signed release.' }
    : { className: 'bad', textContent: `${bad} file(s) don't match or couldn't be checked. Don't enter passwords, and tell us at support@alo.ne.` })
  button.disabled = false
})
