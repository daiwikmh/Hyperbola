import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const artifacts = join(here, '../../hyberbola/out');
const target = join(here, '../src/lib/abis.ts');

const contracts = [
	['QuoteRegistry', 'registryAbi'],
	['ArbitrageurVault', 'vaultAbi'],
	['RediSwapSandwichHook', 'hookAbi'],
];

let out = '// Generated from hyberbola/out by scripts/sync-abis.mjs. Do not edit by hand.\n\n';

for (const [contract, name] of contracts) {
	const artifact = JSON.parse(readFileSync(join(artifacts, `${contract}.sol/${contract}.json`), 'utf8'));
	const abi = artifact.abi.filter((e) => e.type === 'function' || e.type === 'event' || e.type === 'error');
	out += `export const ${name} = ${JSON.stringify(abi, null, 2)} as const;\n\n`;
}

writeFileSync(target, out);
console.log(`wrote ${target}`);
