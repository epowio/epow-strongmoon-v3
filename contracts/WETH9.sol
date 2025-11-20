// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal WETH9-compatible implementation for 0.8.x
contract WETH9 {
    string public name = "Wrapped ETH";
    string public symbol = "WETH";
    uint8  public decimals = 18;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);
    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint wad) public {
        require(balanceOf[msg.sender] >= wad, "insufficient WETH");
        balanceOf[msg.sender] -= wad;
        emit Withdrawal(msg.sender, wad);
        emit Transfer(msg.sender, address(0), wad);
        payable(msg.sender).transfer(wad);
    }

    function totalSupply() public view returns (uint) {
        return address(this).balance;
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad) public returns (bool) {
        require(balanceOf[src] >= wad, "insufficient");
        if (src != msg.sender) {
            uint allowed = allowance[src][msg.sender];
            require(allowed >= wad, "not allowed");
            if (allowed != type(uint).max) allowance[src][msg.sender] = allowed - wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }
}
