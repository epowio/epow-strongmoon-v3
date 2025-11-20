// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPool {}

contract MockNonfungiblePositionManager {
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

    address public immutable pool;

    MintParams public lastMintParams;
    address public lastSafeTransferFromFrom;
    address public lastSafeTransferFromTo;
    uint256 public lastSafeTransferFromTokenId;
    uint256 public nextTokenId = 1;

    event PoolCreated(address pool);
    event MintCalled(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event SafeTransferFrom(address from, address to, uint256 tokenId);

    constructor() {
        pool = address(new MockPool());
        emit PoolCreated(pool);
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address) {
        // For tests, just return the same pool.
        // You can add extra checks/asserts here if needed.
        token0; token1; fee; sqrtPriceX96; // silence warnings
        return pool;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        lastMintParams = params;
        tokenId = nextTokenId++;
        liquidity = 1e6;
        // Simulate full usage of desired amounts (no dust)
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        emit MintCalled(tokenId, liquidity, amount0, amount1);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        lastSafeTransferFromFrom = from;
        lastSafeTransferFromTo = to;
        lastSafeTransferFromTokenId = tokenId;
        emit SafeTransferFrom(from, to, tokenId);
    }
}
