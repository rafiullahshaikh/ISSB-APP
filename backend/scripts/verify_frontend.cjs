// Read-only smoke checks; no application code is modified or run with real user data.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
let count = 0;
for (const name of ['index.html', 'wat-practice.html', 'wat-results.html', 'wat-dashboard.html']) {
  const html = fs.readFileSync(path.join(root, name), 'utf8');
  for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (/\bsrc\s*=|type\s*=\s*["'](?:application\/ld\+json|application\/json)["']/i.test(match[1])) continue;
    new vm.Script(match[2], { filename: name });
    count++;
  }
  for (const match of html.matchAll(/(?:href|src)\s*=\s*["']([^"']+\.html)(?:[?#][^"']*)?["']/gi)) {
    if (/^https?:/i.test(match[1])) continue;
    if (!fs.existsSync(path.resolve(root, match[1]))) throw new Error(`${name}: missing local HTML link`);
  }
}
console.log(`PASS: ${count} inline scripts parse; local HTML links resolve across all four pages`);
