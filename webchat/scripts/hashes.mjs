import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const dist = join(root, 'dist')
const site = process.env.WEBCHAT_SITE || 'https://chat.alo.ne/web'

const walk = dir => readdirSync(dir).flatMap(name => {
  const path = join(dir, name)
  return statSync(path).isDirectory() ? walk(path) : [path]
})

const lines = walk(dist).sort().map(path => {
  const hash = createHash('sha256').update(readFileSync(path)).digest('hex')
  return `${hash}  /${relative(dist, path).split(sep).join('/')}`
})

const output = `alo.ne webchat release ${new Date().toISOString().slice(0, 10)}

Check that ${site} serves exactly this release:
  1. gpg --verify this file (key fingerprint: GitHub, Discord and keys.openpgp.org)
  2. Save the hash lines below as hashes.txt, then run:
     while read -r hash path; do curl -s --create-dirs -o "./web$path" "${site}$path"; done < hashes.txt
     sed 's#  /#  ./web/#' hashes.txt | sha256sum -c
     Every line must say OK.

This is strong evidence the code was not swapped, not certainty. For the strongest protection use an app.

${lines.join('\n')}
`

writeFileSync(join(root, 'hashes.txt'), output)
console.log(`Wrote hashes.txt (${lines.length} files). Sign it with: gpg --clearsign hashes.txt`)
