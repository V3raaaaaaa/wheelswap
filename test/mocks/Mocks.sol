// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueek.sol";

contract MockCore is ISqueekCore {
    CoreState internal s;

    constructor(uint64 work, uint64 height, uint32 difficulty) {
        s.cumulativeWork = work;
        s.blockHeight = height;
        s.workPerThousandBlocks = difficulty;
    }

    function state() external view returns (CoreState memory) {
        return s;
    }

    function addWork(uint64 w) external {
        s.cumulativeWork += w;
    }

    function addBlocks(uint64 b) external {
        s.blockHeight += b;
    }

    function setDifficulty(uint32 d) external {
        s.workPerThousandBlocks = d;
    }
}

/// @dev Plain ERC-20 with EIP-2612 permit, shaped like OpenZeppelin's (what SqueekToken is).
contract MockSQK {
    string public constant name = "Squeek";
    string public constant symbol = "SQK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 v) external {
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        emit Approval(msg.sender, sp, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _xfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= v, "allowance");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        _xfer(f, t, v);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "permit expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address rec = ecrecover(digest, v, r, s);
        require(rec != address(0) && rec == owner, "bad sig");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _xfer(address f, address t, uint256 v) internal {
        require(balanceOf[f] >= v, "balance");
        balanceOf[f] -= v;
        balanceOf[t] += v;
        emit Transfer(f, t, v);
    }
}

/// @dev Re-enters the pool from its ETH receive hook.
contract Reenterer {
    address payable public pool;
    bool public armed;

    constructor(address payable p) {
        pool = p;
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            (bool ok,) = pool.call(
                abi.encodeWithSignature("swapExactETHForSQK(uint256,address,uint256)", 0, address(this), block.timestamp)
            );
            require(ok, "reentry blocked");
        }
    }
}
