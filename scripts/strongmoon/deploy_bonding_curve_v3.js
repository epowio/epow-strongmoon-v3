const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const WETH9             = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const V3_FACTORY        = "0xDc4fFC7665087E15e30037223A6dF4a90C63E332";
  const POSITION_MANAGER  = "0x3F08213F8d29f209b6665b6855a64F6791368ec4";

  const Curve = await hre.ethers.getContractFactory("BondingCurve");
  const curve = await Curve.deploy(deployer.address, WETH9, V3_FACTORY, POSITION_MANAGER);
  await curve.waitForDeployment();
  const curveAddr = await curve.getAddress();
  console.log("BondingCurve:", curveAddr);

  const creationFeeWei = await curve.creationFeeWei();
  console.log("creationFeeWei:", creationFeeWei.toString());

  const name = "DemoToken";
  const symbol = "DEMO";
  const tx = await curve.createToken(name, symbol, { value: creationFeeWei });
  const rcpt = await tx.wait();
  console.log("createToken tx hash:", rcpt.hash);

  const tokens = await curve.getUserTokens(deployer.address);
  const tokenAddr = tokens[tokens.length - 1];
  console.log("Token created:", tokenAddr);

  const startPrice = await curve.tokenStartPrices(tokenAddr);
  console.log("Start price (wei):", startPrice.toString());

  const snap = await curve.getAccountingSnapshot(tokenAddr);
  console.log("Snapshot:", {
    contractBalance: snap[0].toString(),
    totalEscrow:     snap[1].toString(),
    tokenEscrow:     snap[2].toString(),
    tokenFunds:      snap[3].toString(),
    lpSeeded:        snap[4],
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
