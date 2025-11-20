const { expect } = require("chai");
const { ethers } = require("hardhat");

// 1e18 as bigint
const WAD = 10n ** 18n;

describe("BondingCurve", function () {
  let owner, user, seller, other;
  let weth, factory, posm, curve;

  async function deployAll() {
    [owner, user, seller, other] = await ethers.getSigners();

    const MockWETH = await ethers.getContractFactory("MockWETH");
    weth = await MockWETH.deploy();
    await weth.waitForDeployment();

    const MockV3Factory = await ethers.getContractFactory("MockV3Factory");
    factory = await MockV3Factory.deploy();
    await factory.waitForDeployment();

    const MockNonfungiblePositionManager =
      await ethers.getContractFactory("MockNonfungiblePositionManager");
    posm = await MockNonfungiblePositionManager.deploy();
    await posm.waitForDeployment();

    const BondingCurve = await ethers.getContractFactory("BondingCurve");
    curve = await BondingCurve.deploy(
      owner.address,
      weth.target,
      factory.target,
      posm.target
    );
    await curve.waitForDeployment();
  }

  beforeEach(async function () {
    await deployAll();
  });

  async function createSimpleToken(creator = user) {
    const creationFee = await curve.creationFeeWei(); // bigint

    await expect(
      curve.connect(creator).createToken("TestToken", "TEST", {
        value: creationFee,
      })
    ).to.emit(curve, "TokenCreated");

    const userTokens = await curve.getUserTokens(creator.address);
    const tokenAddr = userTokens[0];

    const token = await ethers.getContractAt("Token", tokenAddr);
    return { tokenAddr, token, creationFee };
  }

  it("reverts if creation fee is incorrect", async function () {
    const creationFee = await curve.creationFeeWei();

    await expect(
      curve.connect(user).createToken("Foo", "FOO", { value: 0n })
    ).to.be.revertedWith("Send exact creation fee");

    await expect(
      curve.connect(user).createToken("Foo", "FOO", {
        value: creationFee + 1n,
      })
    ).to.be.revertedWith("Send exact creation fee");
  });

  it("creates token and initializes state", async function () {
    const creationFee = await curve.creationFeeWei();

    const tx = await curve.connect(user).createToken("TestToken", "TEST", {
      value: creationFee,
    });
    const receipt = await tx.wait();

    const ev = receipt.logs
      .map((l) => curve.interface.parseLog(l))
      .find((e) => e.name === "TokenCreated");

    const tokenAddr = ev.args.tokenAddress;

    const token = await ethers.getContractAt("Token", tokenAddr);

    const creator = await curve.tokenCreator(tokenAddr);
    expect(creator).to.equal(user.address);

    const startPrice = await curve.tokenStartPrices(tokenAddr);
    const initialPrice = await curve.INITIAL_PRICE_WEI();
    expect(startPrice).to.equal(initialPrice);

    const platformEscrow = await curve.platformEscrow(tokenAddr);
    expect(platformEscrow).to.equal(creationFee);

    const totalEscrow = await curve.totalEscrow();
    expect(totalEscrow).to.equal(creationFee);

    expect(await token.decimals()).to.equal(18);
  });

  it("buyTokens mints tokens, updates accounting, and sends tax to feeCollector", async function () {
    const { tokenAddr } = await createSimpleToken(user);
    const token = await ethers.getContractAt("Token", tokenAddr);

    const amount = 1000;

    const [cost, totalCost] = await curve.calculateCost(tokenAddr, amount);
    const tax = totalCost - cost;

    const feeCollector = await curve.feeCollector();
    const feeBefore = await ethers.provider.getBalance(feeCollector);
    const contractBefore = await ethers.provider.getBalance(curve.target);

    await expect(
      curve.connect(user).buyTokens(tokenAddr, amount, {
        value: totalCost,
      })
    )
      .to.emit(curve, "TokensPurchased")
      .withArgs(user.address, tokenAddr, amount, cost, tax);

    const feeAfter = await ethers.provider.getBalance(feeCollector);
    const contractAfter = await ethers.provider.getBalance(curve.target);

    // Fee collector received exactly the tax
    expect(feeAfter - feeBefore).to.equal(tax);

    // Contract kept only the cost (principal) from this buy
    expect(contractAfter - contractBefore).to.equal(cost);

    // Curve supply updated
    const totalSupply = await curve.tokenTotalSupply(tokenAddr);
    expect(totalSupply).to.equal(BigInt(amount));

    // User token balance
    const bal = await token.balanceOf(user.address);
    expect(bal).to.equal(BigInt(amount) * WAD);

    // tokenFunds accounting should match cost
    const tokenFunds = await curve.tokenFunds(tokenAddr);
    expect(tokenFunds).to.equal(cost);
  });

  it("buyTokens refunds extra ETH", async function () {
    const { tokenAddr } = await createSimpleToken(user);

    const amount = 500;
    const [cost, totalCost] = await curve.calculateCost(tokenAddr, amount);
    const extra = ethers.parseEther("1");

    const contractBefore = await ethers.provider.getBalance(curve.target);

    await curve.connect(user).buyTokens(tokenAddr, amount, {
      value: totalCost + extra,
    });

    const contractAfter = await ethers.provider.getBalance(curve.target);

    // Contract should still only have gained 'cost' from this buy
    expect(contractAfter - contractBefore).to.equal(cost);
  });

  it("sellTokens burns tokens, pays user, and uses escrow for platform fee", async function () {
    const { tokenAddr } = await createSimpleToken(user);
    const token = await ethers.getContractAt("Token", tokenAddr);

    // First: user buys 1,000 tokens
    const buyAmount = 1000;
    const [buyCost, buyTotalCost] = await curve.calculateCost(
      tokenAddr,
      buyAmount
    );

    await curve.connect(user).buyTokens(tokenAddr, buyAmount, {
      value: buyTotalCost,
    });

    // Sanity check
    expect(await curve.tokenTotalSupply(tokenAddr)).to.equal(BigInt(buyAmount));

    // Now sell 100 tokens back
    const sellAmount = 100;
    const [revenue, tax, platformTax] = await curve.calculateRevenue(
      tokenAddr,
      sellAmount
    );

    // Approve curve to pull tokens
    await token
      .connect(user)
      .approve(curve.target, BigInt(sellAmount) * WAD);

    const feeCollector = await curve.feeCollector();
    const feeBefore = await ethers.provider.getBalance(feeCollector);
    const escrowBefore = await curve.platformEscrow(tokenAddr);
    const totalEscrowBefore = await curve.totalEscrow();

    await expect(
      curve.connect(user).sellTokens(tokenAddr, sellAmount)
    ).to.emit(curve, "TokensSold");

    const escrowAfter = await curve.platformEscrow(tokenAddr);
    const totalEscrowAfter = await curve.totalEscrow();
    const feeAfter = await ethers.provider.getBalance(feeCollector);

    // Escrow funded by creation fee should cover full platformTax.
    expect(escrowBefore - escrowAfter).to.equal(platformTax);
    expect(totalEscrowBefore - totalEscrowAfter).to.equal(platformTax);

    // Fee collector gets tax + platformTax
    const expectedToFeeCollector = tax + platformTax;
    expect(feeAfter - feeBefore).to.equal(expectedToFeeCollector);

    // Supply decreased
    const totalSupplyAfter = await curve.tokenTotalSupply(tokenAddr);
    expect(totalSupplyAfter).to.equal(BigInt(buyAmount - sellAmount));

    // tokenFunds decreased by full 'revenue'
    const tokenFundsAfter = await curve.tokenFunds(tokenAddr);
    expect(tokenFundsAfter).to.equal(buyCost - revenue);
  });

  it("topUpEscrow increases token escrow and global escrow", async function () {
    const { tokenAddr } = await createSimpleToken(user);

    const topUp = ethers.parseEther("2");

    const totalEscrowBefore = await curve.totalEscrow();
    const tokenEscrowBefore = await curve.platformEscrow(tokenAddr);

    await expect(
      curve.connect(other).topUpEscrow(tokenAddr, { value: topUp })
    )
      .to.emit(curve, "EscrowTopped")
      .withArgs(tokenAddr, other.address, topUp);

    const totalEscrowAfter = await curve.totalEscrow();
    const tokenEscrowAfter = await curve.platformEscrow(tokenAddr);

    expect(totalEscrowAfter - totalEscrowBefore).to.equal(topUp);
    expect(tokenEscrowAfter - tokenEscrowBefore).to.equal(topUp);
  });

  it("withdrawResidualAfterBonding reverts before LP is seeded", async function () {
    const { tokenAddr } = await createSimpleToken(user);

    await expect(
      curve.withdrawResidualAfterBonding(tokenAddr, owner.address)
    ).to.be.revertedWith("LP not seeded");
  });

  it("seeds UniswapV3 LP when supply crosses LP_CAP_INITIAL and allows residual withdrawal", async function () {
    const { tokenAddr } = await createSimpleToken(user);

    const LP_CAP_INITIAL = await curve.LP_CAP_INITIAL();

    // Optional: top up escrow so we can see withdrawal later.
    const extraEscrow = ethers.parseEther("1");
    await curve.connect(other).topUpEscrow(tokenAddr, { value: extraEscrow });

    // One big buy to jump directly to LP_CAP_INITIAL and trigger seeding.
    const [cost, totalCost] = await curve.calculateCost(
      tokenAddr,
      Number(LP_CAP_INITIAL) // LP_CAP_INITIAL is bigint
    );

    await curve.connect(user).buyTokens(tokenAddr, Number(LP_CAP_INITIAL), {
      value: totalCost,
    });

    expect(await curve.lpCreated(tokenAddr)).to.equal(true);
    expect(await curve.lpSeeded(tokenAddr)).to.equal(true);

    const pool = await curve.tokenV3Pool(tokenAddr);
    expect(pool).to.not.equal(ethers.ZeroAddress);

    // After seeding, tokenFunds for this token must be zero (all used for LP).
    const tokenFunds = await curve.tokenFunds(tokenAddr);
    expect(tokenFunds).to.equal(0n);

    // Residual escrow is withdrawable by contract owner
    const escrowBefore = await curve.platformEscrow(tokenAddr);
    const totalEscrowBefore = await curve.totalEscrow();

    const toBefore = await ethers.provider.getBalance(other.address);

    await expect(
      curve.withdrawResidualAfterBonding(tokenAddr, other.address)
    )
      .to.emit(curve, "EscrowWithdrawn")
      .withArgs(tokenAddr, other.address, escrowBefore);

    const toAfter = await ethers.provider.getBalance(other.address);
    const escrowAfter = await curve.platformEscrow(tokenAddr);
    const totalEscrowAfter = await curve.totalEscrow();

    expect(escrowAfter).to.equal(0n);
    expect(totalEscrowBefore - totalEscrowAfter).to.equal(escrowBefore);
    expect(toAfter - toBefore).to.equal(escrowBefore);
  });

  it("admin setters and ownership transfer work", async function () {
    // setFeeCollector
    await curve.setFeeCollector(other.address);
    expect(await curve.feeCollector()).to.equal(other.address);

    // setLpCollector
    await curve.setLpCollector(user.address);
    expect(await curve.lpCollector()).to.equal(user.address);

    // setCreationFeeWei
    const oldFee = await curve.creationFeeWei();
    const newFee = oldFee * 2n;

    await expect(curve.setCreationFeeWei(newFee))
      .to.emit(curve, "CreationFeeUpdated")
      .withArgs(oldFee, newFee);

    expect(await curve.creationFeeWei()).to.equal(newFee);

    // transferOwnership
    await expect(curve.transferOwnership(user.address))
      .to.emit(curve, "OwnershipTransferred")
      .withArgs(owner.address, user.address);

    expect(await curve.owner()).to.equal(user.address);
  });
});
