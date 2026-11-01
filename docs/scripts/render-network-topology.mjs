import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { render } from "pele";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const sourcePath = resolve(scriptDirectory, "../diagrams/network-topology.mmd");
const outputPath = resolve(scriptDirectory, "../img/network-topology.svg");
const source = await readFile(sourcePath, "utf8");
const { svg } = render(source);

await writeFile(outputPath, svg);
console.log("Rendered network-topology.svg");
