// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal views of the live Squeekchain contracts on Sepolia that Wheelswap reads.
/// Addresses (Sepolia, core-sepolia-20261103):
///   SqueekCore  0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4
///   SQK         0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e  (SqueekToken, ERC-20 + EIP-2612 permit)

interface ISqueekCore {
    struct CoreState {
        uint64 settledThroughRound;
        uint64 cumulativeWork; // every accepted pass of the real wheel = 1 work unit
        uint96 cumulativeBlockUnits;
        uint64 blockHeight; // Squeek blocks (not Ethereum blocks)
        uint96 blockProgress;
        uint32 workPerThousandBlocks; // current difficulty: work expected per 1000 Squeek blocks
        uint256 authorizationNonce;
        bool paused;
    }

    function state() external view returns (CoreState memory result);
}

interface IERC20Permit {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}
