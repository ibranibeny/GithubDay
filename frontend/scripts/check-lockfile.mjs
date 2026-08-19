#!/usr/bin/env node
// Fails if package-lock.json is not portable: internal feed URLs or weak/missing
// integrity hashes. Zero dependencies so it can run before `npm ci`.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const lockPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "package-lock.json");

if (!fs.existsSync(lockPath)) {
  console.error("check-lockfile: package-lock.json is missing (it must be committed)");
  process.exit(1);
}

const raw = fs.readFileSync(lockPath, "utf8");
const lock = JSON.parse(raw);
const errors = [];

const FORBIDDEN = [
  /pkgs\.visualstudio\.com/i,
  /packagefeedproxy/i,
  /pkgs\.dev\.azure\.com/i,
  /_packaging/i,
];
for (const pattern of FORBIDDEN) {
  const hits = raw.match(new RegExp(pattern.source, "gi"));
  if (hits) errors.push(`internal feed reference "${pattern.source}" found ${hits.length}x`);
}

const walk = (container, trail) => {
  for (const [key, value] of Object.entries(container ?? {})) {
    if (!value || typeof value !== "object") continue;
    const where = trail ? `${trail} > ${key}` : key;

    if (typeof value.resolved === "string" && value.resolved.startsWith("http")) {
      const host = new URL(value.resolved).host;
      if (host !== "registry.npmjs.org") errors.push(`${where}: resolved host is "${host}"`);
      if (typeof value.integrity !== "string") {
        errors.push(`${where}: registry entry has no integrity hash`);
      } else if (!value.integrity.startsWith("sha512-")) {
        errors.push(`${where}: integrity is "${value.integrity.split("-")[0]}", expected sha512`);
      }
    }
    if (value.dependencies) walk(value.dependencies, where);
  }
};
walk(lock.packages, "");
walk(lock.dependencies, "");

if (errors.length) {
  console.error(`check-lockfile: ${errors.length} problem(s) in package-lock.json`);
  for (const e of errors.slice(0, 40)) console.error("  - " + e);
  if (errors.length > 40) console.error(`  ...and ${errors.length - 40} more`);
  process.exit(1);
}

const count = Object.values(lock.packages ?? {}).filter((p) => p?.resolved).length;
console.log(
  `check-lockfile: OK - ${count} registry entries, all registry.npmjs.org with sha512 integrity`,
);
