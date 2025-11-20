// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./Token.sol";

// -------------------------------
// Uniswap V3 minimal interfaces
// -------------------------------
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 value) external returns (bool);
}

// -------------------------------
// BondingCurve (V3 seeding version)
// -------------------------------
contract BondingCurve is ReentrancyGuard { 
    // 16,156 Ethw
    // uint256 public constant INITIAL_PRICE_WEI = 50050000;
    // uint256 public constant INCREMENT_WEI     = 50000; 

    // For Testing on ETHW Mainnet 
    uint256 public constant INITIAL_PRICE_WEI = 50050;
    uint256 public constant INCREMENT_WEI     = 50;      // Linear increment per token along the curve

    uint256 public constant MAX_SUPPLY     = 1_000_000_000; // Absolute hard cap (whole tokens)
    uint256 public constant CURVE_CAP      = 800_000_000;   // Curve stops allowing buys at this supply
    uint256 public constant LP_CAP_INITIAL = 799_900_000;   // Crossing this triggers LP creation/seed
    uint256 public constant LP_CAP         = 200_000_000;   // Base tokens minted into LP at seeding

    // --- TEST PRESET: ultra-cheap seeding ---
    // uint256 public constant INITIAL_PRICE_WEI = 1_000_000_000_000; // 1e12 wei = 0.000001 ETHW per token
    // uint256 public constant INCREMENT_WEI     = 0;

    // uint256 public constant MAX_SUPPLY     = 10_000; // small for tests
    // uint256 public constant CURVE_CAP      = 8_000;  // curve stops at 8k
    // uint256 public constant LP_CAP_INITIAL = 7_999;  // crossing triggers v3 seed
    // uint256 public constant LP_CAP         = 2_000;  // tokens minted to LP at seeding
    // --- TEST PRESET END ---

    uint256 public constant TAX_PERCENTAGE = 1; // 1% buy tax; sell path also applies 1% + platform 1%
    uint256 private constant WAD = 1e18;       // 18 decimals per ERC-20 whole token

    address payable public owner;

    address payable public feeCollector;
    address public lpCollector;

    // --- Creation fee (configurable; default 0.1 ETHW) ---
    uint256 public creationFeeWei = 0.1 ether;
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);

    // --- Global registry of created tokens ---
    address[] public allTokens;

    // --- Per-user state ---
    mapping(address => address[]) public userTokens;

    // --- Per-token state ---
    mapping(address => uint256) public tokenStartPrices;             // Derived visible start price
    mapping(address => mapping(address => uint256)) public tokensPurchased;
    mapping(address => uint256) public tokenFunds;                   // ETH accrued from buys (pre-LP)
    mapping(address => uint256) public tokenTotalSupply;             // Curve counter (whole tokens)

    // --- Platform escrow (per token) ---
    mapping(address => uint256) public platformEscrow;
    mapping(address => address) public tokenCreator;                 // Whitelist of valid tokens

    // --- LP single-fire flags ---
    mapping(address => bool) public lpCreated;
    mapping(address => bool) public lpSeeded;

    // --- Escrow accounting across all tokens ---
    uint256 public totalEscrow;

    // --- Events ---
    event TokensPurchased(address indexed buyer, address indexed token, uint256 amount, uint256 cost, uint256 tax);
    event TokensSold(
        address indexed seller,
        address indexed token,
        uint256 amount,
        uint256 revenue,
        uint256 tax,
        uint256 platformTaxUserPaid,
        uint256 platformTaxFromEscrow
    );
    event TokenCreated(address indexed creator, string name, string symbol, address tokenAddress);
    event LPSeeded(address indexed token, address indexed pool, uint256 tokenAmount, uint256 ethAmount, address lpTo);

    event FeeCollectorUpdated(address indexed newCollector);
    event LpCollectorUpdated(address indexed newCollector);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event EscrowTopped(address indexed token, address indexed from, uint256 amount);
    event EscrowWithdrawn(address indexed token, address indexed to, uint256 amount);

    // -------------------------------
    // Uniswap V3 config (1% tier)
    // -------------------------------
    address public immutable WETHW;
    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable posm;

    // Use the 1.00% fee tier
    uint24 public constant V3_FEE = 10_000;     // 1%
    bool   public constant V3_FULL_RANGE = true;

    // Canonical tick bounds (Uniswap V3)
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    // Cache created pools
    mapping(address => address) public tokenV3Pool;

    constructor(
        address payable _contractCreator,
        address _WETHW,
        address _v3Factory,
        address _posm
    ) {
        owner = _contractCreator;

        feeCollector = _contractCreator;
        lpCollector  = _contractCreator;

        WETHW     = _WETHW;
        v3Factory = IUniswapV3Factory(_v3Factory);
        posm      = INonfungiblePositionManager(_posm);

        emit OwnershipTransferred(address(0), _contractCreator);
    }

    // --- Modifiers ---
    modifier onlyContractOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // --- Ownership ---
    function transferOwnership(address payable newOwner) external onlyContractOwner {
        require(newOwner != address(0), "newOwner=0");
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    // --- Admin setters ---
    function setFeeCollector(address payable _feeCollector) external onlyContractOwner {
        require(_feeCollector != address(0), "feeCollector=0");
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector);
    }

    function setLpCollector(address _lpCollector) external onlyContractOwner {
        require(_lpCollector != address(0), "lpCollector=0");
        lpCollector = _lpCollector;
        emit LpCollectorUpdated(_lpCollector);
    }

    function setCreationFeeWei(uint256 newFee) external onlyContractOwner {
        uint256 old = creationFeeWei;
        creationFeeWei = newFee;
        emit CreationFeeUpdated(old, newFee);
    }

    // --- Math: buy cost ---
    function calculateCost(address tokenAddress, uint256 amount)
        public
        view
        returns (uint256 cost, uint256 totalCost)
    {
        require(tokenCreator[tokenAddress] != address(0), "Unknown token");
        require(amount > 0, "Amount=0");
        require(tokenTotalSupply[tokenAddress] + amount <= CURVE_CAP, "Bonding curve limit reached");

        uint256 startPrice = INITIAL_PRICE_WEI + (tokenTotalSupply[tokenAddress] * INCREMENT_WEI);
        uint256 endPrice   = startPrice + ((amount - 1) * INCREMENT_WEI);
        cost = (amount * (startPrice + endPrice)) / 2; // arithmetic series sum
        uint256 tax = (cost * TAX_PERCENTAGE) / 100;
        totalCost = cost + tax;
    }

    // --- Math: sell revenue (sell disabled after LP_CAP_INITIAL) ---
    function calculateRevenue(address tokenAddress, uint256 amount)
        public
        view
        returns (uint256 revenue, uint256 tax, uint256 platformTax)
    {
        require(tokenCreator[tokenAddress] != address(0), "Unknown token");
        require(amount > 0, "Amount=0");
        require(tokenTotalSupply[tokenAddress] >= amount, "Insufficient curve supply");

        uint256 endPrice   = INITIAL_PRICE_WEI + ((tokenTotalSupply[tokenAddress] - 1) * INCREMENT_WEI);
        uint256 startPrice = endPrice - ((amount - 1) * INCREMENT_WEI);

        revenue     = (amount * (startPrice + endPrice)) / 2;
        tax         = (revenue * TAX_PERCENTAGE) / 100;
        platformTax = (revenue * 1) / 100; // separate 1% platform component
    }

    function buyTokens(address tokenAddress, uint256 amount) external payable nonReentrant {
        require(tokenCreator[tokenAddress] != address(0), "Unknown token");
        uint256 pre = tokenTotalSupply[tokenAddress];
        require(pre + amount <= MAX_SUPPLY, "Max supply");

        (uint256 cost, uint256 totalCost) = calculateCost(tokenAddress, amount);
        require(msg.value >= totalCost, "Insufficient ETH");

        uint256 tax = totalCost - cost;

        // Effects
        uint256 post = pre + amount;
        tokenTotalSupply[tokenAddress] = post;

        Token userToken = Token(tokenAddress);
        userToken.mint(msg.sender, amount * WAD);

        // Account ETH for LP
        tokensPurchased[tokenAddress][msg.sender] += amount;
        tokenFunds[tokenAddress] += cost;

        _createPoolFlag(tokenAddress, post);
        _seedLPIfNeededV3(tokenAddress, post, userToken, tax);
        _updateStartPrice(tokenAddress);

        // Interactions
        if (tax > 0) {
            (bool taxSuccess, ) = feeCollector.call{value: tax}("");
            require(taxSuccess, "Tax transfer failed");
        }

        if (msg.value > totalCost) {
            uint256 refundAmt = msg.value - totalCost;
            (bool refundSuccess, ) = msg.sender.call{value: refundAmt}("");
            require(refundSuccess, "Refund failed");
        }

        emit TokensPurchased(msg.sender, tokenAddress, amount, cost, tax);
    }

    function sellTokens(address tokenAddress, uint256 amount) external nonReentrant {
        require(tokenCreator[tokenAddress] != address(0), "Unknown token");

        Token userToken = Token(tokenAddress);
        require(userToken.balanceOf(msg.sender) >= amount * WAD, "Insufficient tokens");
        require(userToken.allowance(msg.sender, address(this)) >= amount * WAD, "Allowance too low");

        require(tokenTotalSupply[tokenAddress] <= LP_CAP_INITIAL, "Bonding curve hit");

        (uint256 revenue, uint256 tax, uint256 platformTax) = calculateRevenue(tokenAddress, amount);

        uint256 fromEscrow = 0;
        if (platformEscrow[tokenAddress] >= platformTax) {
            platformEscrow[tokenAddress] -= platformTax;
            totalEscrow -= platformTax;
            (bool ok1, ) = feeCollector.call{value: platformTax}("");
            require(ok1, "Platform fee payout failed");
            fromEscrow = platformTax;
        }

        uint256 platformTaxUserPaid = platformTax - fromEscrow;
        uint256 netRevenue = revenue - tax - platformTaxUserPaid;

        require(address(this).balance >= netRevenue, "Contract underfunded");

        userToken.transferFrom(msg.sender, address(this), amount * WAD);
        userToken.burn(amount * WAD);
        tokenTotalSupply[tokenAddress] -= amount;

        uint256 tf = tokenFunds[tokenAddress];
        tokenFunds[tokenAddress] = tf > revenue ? tf - revenue : 0;

        _updateStartPrice(tokenAddress);

        // Interactions
        if (tax > 0) {
            (bool tOk, ) = feeCollector.call{value: tax}("");
            require(tOk, "Tax payout failed");
        }

        if (platformTaxUserPaid > 0) {
            (bool ptOk, ) = feeCollector.call{value: platformTaxUserPaid}("");
            require(ptOk, "Platform tax forward failed");
        }

        (bool pOk, ) = msg.sender.call{value: netRevenue}("");
        require(pOk, "Payout failed");

        emit TokensSold(msg.sender, tokenAddress, amount, revenue, tax, platformTaxUserPaid, fromEscrow);
    }

    function topUpEscrow(address token) external payable nonReentrant {
        require(tokenCreator[token] != address(0), "Unknown token");
        require(msg.value > 0, "No ETH");
        platformEscrow[token] += msg.value;
        totalEscrow += msg.value;

        emit EscrowTopped(token, msg.sender, msg.value);
    }

    function createToken(string memory name, string memory symbol) external payable nonReentrant {
        // Enforce exact creation fee (default 0.1 ETHW; adjustable via setCreationFeeWei)
        require(msg.value == creationFeeWei, "Send exact creation fee");

        Token newToken = new Token(name, symbol);
        require(newToken.decimals() == 18, "Token must be 18 decimals");

        userTokens[msg.sender].push(address(newToken));
        allTokens.push(address(newToken));

        newToken.setBondingCurveContract(address(this));
        tokenStartPrices[address(newToken)] = INITIAL_PRICE_WEI;

        // Treat the creation fee as platform escrow for this token
        platformEscrow[address(newToken)] += msg.value;
        totalEscrow += msg.value;
        tokenCreator[address(newToken)] = msg.sender;

        emit TokenCreated(msg.sender, name, symbol, address(newToken));
    }

    // --- Owner withdrawal: per-token residual after bonding only ---
    function withdrawResidualAfterBonding(address token, address payable to)
        external
        onlyContractOwner
        nonReentrant
    {
        require(to != address(0), "to=0");
        require(lpSeeded[token], "LP not seeded");
        require(tokenCreator[token] != address(0), "unknown token");

        uint256 amount = platformEscrow[token];
        require(amount > 0, "No residual");

        platformEscrow[token] = 0;
        totalEscrow -= amount;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit EscrowWithdrawn(token, to, amount);
    }

    // -------------------------------
    // Internals — V3 seeding path
    // -------------------------------

    // Mark that we crossed the threshold; actual pool creation happens during seed
    function _createPoolFlag(address tokenAddress, uint256 post) internal {
        if (!lpCreated[tokenAddress] && post >= LP_CAP_INITIAL) {
            lpCreated[tokenAddress] = true;
        }
    }

    // V3 seed on first cross of LP_CAP_INITIAL
    function _seedLPIfNeededV3(
        address tokenAddress,
        uint256 post,
        Token userToken,
        uint256 pendingTax
    ) internal {
        if (lpSeeded[tokenAddress] || post < LP_CAP_INITIAL) return;

        require(post <= CURVE_CAP, "post > CURVE_CAP");

        uint256 remainingToCap = CURVE_CAP - post;        // [0 .. 100,000]
        uint256 lpMintTokens   = LP_CAP + remainingToCap; // extend token side with remaining
        uint256 tokenAmountWei = lpMintTokens * WAD;

        uint256 ethAmountWei = tokenFunds[tokenAddress];
        require(ethAmountWei > 0, "No ETH accrued for LP");

        // Reset accounting BEFORE external calls
        tokenFunds[tokenAddress] = 0;
        lpSeeded[tokenAddress] = true;

        // Mint the token side to this contract
        userToken.mint(address(this), tokenAmountWei);

        // Determine price token1/token0 with 18d scaling
        bool memeIsToken0 = address(userToken) < WETHW;
        require(tokenAmountWei > 0 && ethAmountWei > 0, "LP amounts zero");

        uint256 price1e18 = memeIsToken0
            ? (ethAmountWei * 1e18) / tokenAmountWei   // price = WETHW / MEME
            : (tokenAmountWei * 1e18) / ethAmountWei;  // price = MEME / WETHW

        uint160 sqrtPriceX96 = _encodeSqrtPriceX96(price1e18);

        // Ensure pool exists & is initialized
        address pool = _ensureV3PoolInitialized(address(userToken), V3_FEE, sqrtPriceX96);
        tokenV3Pool[address(userToken)] = pool;

        // Mint full-range LP and send NFT to lpCollector
        _mintV3Position(address(userToken), V3_FEE, tokenAmountWei, ethAmountWei, sqrtPriceX96, pendingTax);

        emit LPSeeded(tokenAddress, pool, tokenAmountWei, ethAmountWei, lpCollector);
    }

    function _ensureV3PoolInitialized(
        address memeToken,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (address pool) {
        address t0 = memeToken < WETHW ? memeToken : WETHW;
        address t1 = memeToken < WETHW ? WETHW : memeToken;

        pool = v3Factory.getPool(t0, t1, fee);
        if (pool == address(0)) {
            pool = posm.createAndInitializePoolIfNecessary(t0, t1, fee, sqrtPriceX96);
        }
    }

    function _mintV3Position(
        address memeToken,
        uint24 fee,
        uint256 amountToken,   // 18d
        uint256 amountEthWei,  // wei
        uint160 /*sqrtPriceX96*/,
        uint256 pendingTax
    ) internal {
        require(lpCollector != address(0), "lpCollector=0");

        bool memeIsToken0 = memeToken < WETHW;
        address token0 = memeIsToken0 ? memeToken : WETHW;
        address token1 = memeIsToken0 ? WETHW : memeToken;

        // Wrap ETHW -> WETHW
        IWETH(WETHW).deposit{value: amountEthWei}();

        // Approvals to POSM (allow full amounts; mint will take only what it needs)
        IERC20(memeToken).approve(address(posm), amountToken);
        IERC20(WETHW).approve(address(posm), amountEthWei);

        // Full-range ticks aligned to spacing (no shadowing, no equality)
        int24 spacing   = _tickSpacing(fee);
        int24 tickLower = _alignDown(MIN_TICK, spacing);
        int24 tickUpper = _alignDown(MAX_TICK, spacing);
        if (tickLower >= tickUpper) {
            // ensure strictly increasing; minimal wide band fallback
            tickUpper = tickLower + spacing * 2;
        }

        // Desired amounts in token0/token1 order
        uint256 amount0Desired = memeIsToken0 ? amountToken  : amountEthWei;
        uint256 amount1Desired = memeIsToken0 ? amountEthWei : amountToken;

        INonfungiblePositionManager.MintParams memory p = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 30 minutes
        });

        (uint256 tokenId, , uint256 used0, uint256 used1) = posm.mint(p);

        // Send LP-NFT to the collector (locker or multisig recommended)
        posm.safeTransferFrom(address(this), lpCollector, tokenId);

        // --- Send leftover directly to lpCollector ---
        uint256 unused0 = amount0Desired > used0 ? (amount0Desired - used0) : 0;
        uint256 unused1 = amount1Desired > used1 ? (amount1Desired - used1) : 0;

        if (memeIsToken0) {
            // token0 = meme, token1 = WETHW
            if (unused0 > 0) require(IERC20(memeToken).transfer(lpCollector, unused0), "meme dust xfer fail");
            if (unused1 > 0) require(IERC20(WETHW).transfer(lpCollector, unused1), "weth dust xfer fail");
        } else {
            // token0 = WETHW, token1 = meme
            if (unused1 > 0) require(IERC20(memeToken).transfer(lpCollector, unused1), "meme dust xfer fail");
            if (unused0 > 0) require(IERC20(WETHW).transfer(lpCollector, unused0), "weth dust xfer fail");
        }

        // Forward *free* ETHW (respecting escrow + current tax). We never unwrap WETHW here.
        uint256 bal = address(this).balance;
        uint256 reserved = totalEscrow + pendingTax;
        if (bal > reserved) {
            uint256 freeEth = bal - reserved;
            if (freeEth > 0) {
                (bool ok, ) = payable(lpCollector).call{value: freeEth}("");
                require(ok, "eth dust xfer fail");
            }
        }

        // Optional: revoke approvals here if you want tighter allowances.
        // IERC20(memeToken).approve(address(posm), 0);
        // IERC20(WETHW).approve(address(posm), 0);
    }

    function _updateStartPrice(address tokenAddress) internal {
        uint256 currentTotalSupply = tokenTotalSupply[tokenAddress];
        tokenStartPrices[tokenAddress] = INITIAL_PRICE_WEI + (currentTotalSupply * INCREMENT_WEI);
    }

    // -------------------------------
    // Price & tick helpers (18/18)
    // -------------------------------
    // Babylonian sqrt for uint256
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) / 2;
        while (z < x) { x = z; z = (y / z + z) / 2; }
    }

    // Encode sqrtPriceX96 from price1e18 = token1/token0 scaled by 1e18
    // sqrtPriceX96 = sqrt(price1e18) * 2^96 / 1e9
    function _encodeSqrtPriceX96(uint256 price1e18) internal pure returns (uint160) {
        require(price1e18 > 0, "price=0");
        uint256 sqrtPrice1e18 = _sqrt(price1e18);
        uint256 num = sqrtPrice1e18 << 96; // * 2^96
        uint256 x = num / 1e9;             // / 1e9 to match sqrt(1e18)
        require(x <= type(uint160).max, "sqrtPrice overflow");
        return uint160(x);
    }

    function _tickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100)    return 1;   // 0.01%
        if (fee == 500)    return 10;  // 0.05%
        if (fee == 3000)   return 60;  // 0.30%
        if (fee == 10_000) return 200; // 1.00%
        return 200;
    }

    function _nearestUsableTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r >= spacing / 2)  return tick + (spacing - r);
        if (r <= -spacing / 2) return tick - (spacing + r);
        return tick - r;
    }

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        // floors tick to nearest multiple of spacing, staying within int24
        int24 r = tick % spacing;
        return tick - r;
    }

    // --- Debug / visibility helpers ---
    function getAccountingSnapshot(address token) external view returns (
        uint256 contractBalance,
        uint256 globalEscrow,
        uint256 tokenEscrow,
        uint256 tokenFundsAccounting,
        bool lpAlreadySeeded
    ) {
        return (
            address(this).balance,
            totalEscrow,
            platformEscrow[token],
            tokenFunds[token],
            lpSeeded[token]
        );
    }

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    receive() external payable {}
}
