// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 v);
    event Approval(address indexed owner, address indexed spender, uint256 v);

    constructor(string memory _n, string memory _s, uint8 _d, uint256 _supply) {
        name = _n; symbol = _s; decimals = _d;
        _mint(msg.sender, _supply);
    }

    function _mint(address to, uint256 v) internal {
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "bal");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        emit Transfer(msg.sender, to, v);
        return true;
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        emit Approval(msg.sender, sp, v);
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        require(balanceOf[f] >= v, "bal");
        uint256 a = allowance[f][msg.sender];
        require(a >= v, "allow");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        emit Transfer(f, t, v);
        return true;
    }
}
