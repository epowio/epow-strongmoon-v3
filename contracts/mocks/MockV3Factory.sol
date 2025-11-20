// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal stub just to satisfy BondingCurve tests.
// BondingCurve only calls getPool() and never calls createPool() directly.
contract MockV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }

    function createPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}
