// scripts/gen_stdjson_bondingcurve.js
const fs = require("fs");
const path = require("path");

const TARGET_SRC = "contracts/BondingCurve.sol";
const TARGET_NAME = "BondingCurve";

function findBuildInfoFor(contractSrc, contractName) {
  const dir = path.join(process.cwd(), "artifacts", "build-info");
  const files = fs.readdirSync(dir);

  for (const f of files) {
    const full = path.join(dir, f);
    const bi = JSON.parse(fs.readFileSync(full, "utf8"));

    const out = bi.output && bi.output.contracts ? bi.output.contracts : {};
    const contractsInFile = out[contractSrc] || {};
    const hit = contractsInFile[contractName];

    if (hit && hit.evm && hit.evm.bytecode && hit.evm.bytecode.object) {
      return { buildInfoPath: full, bi, hit };
    }
  }
  return null;
}

function main() {
  const found = findBuildInfoFor(TARGET_SRC, TARGET_NAME);
  if (!found) {
    console.error(
      `Could not find build-info for ${TARGET_SRC}:${TARGET_NAME}. Run "npx hardhat compile" first.`
    );
    process.exit(1);
  }

  const { bi } = found;
  const input = bi.input || bi.solcInput;
  if (!input) {
    console.error("No solc input found in build-info (bi.input / bi.solcInput missing).");
    process.exit(1);
  }

  // Optional: drop mocks and tests from sources to keep JSON clean
  for (const file of Object.keys(input.sources)) {
    const lower = file.toLowerCase();
    if (
      lower.includes("mock") ||
      lower.includes("/mocks/") ||
      lower.includes("/test/")
    ) {
      delete input.sources[file];
    }
  }

  // Force settings to match your deployment
  if (!input.settings) input.settings = {};
  if (!input.settings.optimizer) input.settings.optimizer = {};

  input.settings.optimizer.enabled = true;
  input.settings.optimizer.runs = 500;
  input.settings.viaIR = true;

  const outPath = path.join(process.cwd(), "stdjson-bondingcurve.json");
  fs.writeFileSync(outPath, JSON.stringify(input, null, 2), "utf8");

  console.log(`Wrote standard JSON input to: ${outPath}`);
}

main();
