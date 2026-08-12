#!/usr/bin/env node
// Concatena src/*.js + bin/cli.js en un unico archivo ESM ejecutable con `node`, sin bundler
// externo -- el paquete no tiene dependencias, asi que un script de concatenacion basta. Ver
// docs/plans/nmap-sabana-corp.md, "Distribucion al participante", capa 2.
//
// Uso: node scripts/build-bundle.mjs [ruta-de-salida]
// Por defecto escribe en dist/nmap-sabana-corp.mjs (relativo a este paquete).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PKG_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

// Orden de dependencias: cada archivo solo puede importar de los que ya vinieron antes en esta
// lista. catalog.js no depende de nadie; cli.js depende de todos los demas.
const MODULE_ORDER = ['src/catalog.js', 'src/scope.js', 'src/scan.js', 'src/names.js', 'src/render.js', 'bin/cli.js']

const LOCAL_IMPORT_LINE = /^import\s+.*\sfrom\s+['"]\.\.?\/.*['"]\s*$/m

function stripLocalImportsAndExports(source) {
  return source
    .split('\n')
    .filter((line) => !LOCAL_IMPORT_LINE.test(line))
    .map((line) => line.replace(/^export\s+(?=(function|class|const|let|async function))/, ''))
    .join('\n')
}

function buildBundle() {
  const parts = [
    '#!/usr/bin/env node',
    '// GENERADO por scripts/build-bundle.mjs -- no editar a mano, se regenera.',
    '// Bundle de un solo archivo de nmap-sabana-corp, sin dependencias externas.',
    '// Fuente: tools/nmap-sabana-corp/{src,bin} en sabana-corp-cloud.',
    ''
  ]

  for (const relPath of MODULE_ORDER) {
    const source = fs.readFileSync(path.join(PKG_DIR, relPath), 'utf8')
    parts.push(`// ---- ${relPath} ----`)
    parts.push(stripLocalImportsAndExports(source).replace(/^#!.*\n/, ''))
  }

  return parts.join('\n')
}

function main() {
  const pkgVersion = JSON.parse(fs.readFileSync(path.join(PKG_DIR, 'package.json'), 'utf8')).version
  const catalogSource = fs.readFileSync(path.join(PKG_DIR, 'src/catalog.js'), 'utf8')
  const catalogVersion = /VERSION\s*=\s*'([^']+)'/.exec(catalogSource)?.[1]
  if (pkgVersion !== catalogVersion) {
    console.error(
      `[ERROR] package.json version (${pkgVersion}) != src/catalog.js VERSION (${catalogVersion}) -- ` +
        'mantenlas sincronizadas antes de generar el bundle.'
    )
    process.exit(1)
  }

  const outPath = process.argv[2] ?? path.join(PKG_DIR, 'dist', 'nmap-sabana-corp.mjs')
  fs.mkdirSync(path.dirname(outPath), { recursive: true })
  fs.writeFileSync(outPath, buildBundle())
  fs.chmodSync(outPath, 0o755)
  console.log(`generado: ${outPath}`)
}

main()
