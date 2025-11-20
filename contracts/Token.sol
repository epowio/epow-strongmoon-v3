// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Token is
    ERC20,
    ERC20Burnable // Inherit from ERC20Burnable
{
    address public owner;
    address public bondingCurveContract;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        owner = msg.sender; // The owner of the token (typically the deployer)
    }

    // Set the BondingCurve contract address (allowing it to mint tokens)
    function setBondingCurveContract(address _bondingCurveContract) external {
        require(
            msg.sender == owner,
            "Only the owner can set the BondingCurve contract"
        );
        bondingCurveContract = _bondingCurveContract;
    }

    // Mint tokens to the specified address
    function mint(address to, uint256 amount) external {
        require(
            msg.sender == owner || msg.sender == bondingCurveContract,
            "Only the owner or BondingCurve contract can mint tokens"
        );
        _mint(to, amount);
    }

    // Override decimals() to ensure the token uses 18 decimals
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
}