// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WheelSwap} from "../src/WheelSwap.sol";
import {ISqueekCore, IERC20Permit} from "../src/interfaces/ISqueek.sol";

/// Runs against the live Squeekchain deployment on Sepolia:
///   SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-contract Fork
contract WheelSwapForkTest is Test {
    address constant CORE = 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4;
    address constant SQK = 0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e;

    WheelSwap pool;
    IERC20Permit sqk = IERC20Permit(SQK);
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    uint256 dust;

    function setUp() public {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        // public RPCs are load-balanced across nodes that may lag a few blocks: pin a settled block
        vm.rollFork(block.number - 20);
        pool = new WheelSwap(CORE, SQK);
        // Foundry's deterministic test addresses already hold stray Sepolia ETH from other people's
        // runs (nonce-1 address had 0.379 ETH). It sits outside the reserves until someone skims.
        dust = address(pool).balance;

        deal(SQK, lp, 10_000e18);
        deal(SQK, trader, 1_000e18);
        vm.deal(lp, 10 ether);
        vm.deal(trader, 10 ether);
        vm.prank(lp);
        sqk.approve(address(pool), type(uint256).max);
        vm.prank(trader);
        sqk.approve(address(pool), type(uint256).max);
    }

    function testFork_constructorSnapshotsLiveCore() public view {
        ISqueekCore.CoreState memory s = ISqueekCore(CORE).state();
        assertEq(pool.lastWork(), s.cumulativeWork);
        assertEq(pool.lastHeight(), s.blockHeight);
        assertGt(s.blockHeight, 0);
        assertGt(s.workPerThousandBlocks, 0);
    }

    function testFork_currentWheel_isValidTier() public view {
        (WheelSwap.Wheel w, uint16 fee, uint64 work, uint64 height, uint32 diff) = pool.currentWheel();
        assertTrue(fee == 10 || fee == 30 || fee == 50);
        assertEq(fee, w == WheelSwap.Wheel.ZOOMIES ? 10 : w == WheelSwap.Wheel.JOG ? 30 : 50);
        assertEq(work, pool.lastWork());
        assertEq(height, pool.lastHeight());
        assertGt(diff, 0);
    }

    function testFork_addLiquidity_swapBothWays_remove() public {
        vm.prank(lp);
        (uint256 aS, uint256 aE, uint256 liq) =
            pool.addLiquidity{value: 2 ether}(5_000e18, 0, 0, lp, block.timestamp);
        assertEq(aS, 5_000e18);
        assertEq(aE, 2 ether);
        assertGt(liq, 0);
        assertEq(sqk.balanceOf(address(pool)), 5_000e18);

        vm.prank(trader);
        uint256 outS = pool.swapExactETHForSQK{value: 0.1 ether}(0, trader, block.timestamp);
        assertGt(outS, 0);
        assertEq(sqk.balanceOf(trader), 1_000e18 + outS);

        vm.prank(trader);
        uint256 outE = pool.swapExactSQKForETH(200e18, 0, trader, block.timestamp);
        assertGt(outE, 0);

        (uint112 rS, uint112 rE,) = pool.getReserves();
        assertEq(rS, sqk.balanceOf(address(pool)));
        assertEq(rE, address(pool).balance - dust, "reserves track pool ETH net of pre-existing dust");

        vm.prank(lp);
        (uint256 bS, uint256 bE) = pool.removeLiquidity(liq, 0, 0, lp, block.timestamp);
        // fees accrued: LP gets back at least one side above deposit in value terms; here check sanity
        assertGt(bS, 0);
        assertGt(bE, 0);
        assertEq(pool.balanceOf(lp), 0);
    }

    function testFork_swap_usesLiveSQKTransfer() public {
        vm.prank(lp);
        pool.addLiquidity{value: 1 ether}(1_000e18, 0, 0, lp, block.timestamp);
        uint256 before = sqk.balanceOf(trader);
        vm.prank(trader);
        pool.swapExactSQKForETH(50e18, 0, trader, block.timestamp);
        assertEq(before - sqk.balanceOf(trader), 50e18, "real SqueekToken moved exactly amountIn");
    }

    function testFork_realPermit_addLiquidity() public {
        uint256 pk = 0xBEEF;
        address signer = vm.addr(pk);
        deal(SQK, signer, 1_000e18);
        vm.deal(signer, 2 ether);
        vm.prank(lp);
        pool.addLiquidity{value: 1 ether}(1_000e18, 0, 0, lp, block.timestamp);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typehash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                sqk.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typehash, signer, address(pool), 500e18, sqk.nonces(signer), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(signer);
        (uint256 aS,, uint256 liq) =
            pool.addLiquidityWithPermit{value: 1 ether}(500e18, 0, 0, signer, deadline, v, r, s);
        assertEq(aS, 500e18);
        assertGt(liq, 0);
    }
}
