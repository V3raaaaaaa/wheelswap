// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WheelSwap} from "../src/WheelSwap.sol";
import {MockCore, MockSQK, Reenterer} from "./mocks/Mocks.sol";

contract WheelSwapTest is Test {
    MockCore core;
    MockSQK sqk;
    WheelSwap pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 carolPk = 0xC0FFEE;
    address carol;

    uint256 constant SEED_SQK = 10_000e18;
    uint256 constant SEED_ETH = 10 ether;
    uint32 constant DIFFICULTY = 8_000;

    event Swap(
        address indexed sender,
        uint256 sqkIn,
        uint256 ethIn,
        uint256 sqkOut,
        uint256 ethOut,
        uint16 feeBps,
        WheelSwap.Wheel wheel,
        address indexed to
    );

    function setUp() public {
        carol = vm.addr(carolPk);
        core = new MockCore(1_000, 100, DIFFICULTY);
        sqk = new MockSQK();
        pool = new WheelSwap(address(core), address(sqk));

        for (uint256 i; i < 3; i++) {
            address u = i == 0 ? alice : i == 1 ? bob : carol;
            vm.deal(u, 100 ether);
            sqk.mint(u, 1_000_000e18);
        }
        vm.prank(alice);
        sqk.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        sqk.approve(address(pool), type(uint256).max);
    }

    function _seed() internal returns (uint256 liq) {
        vm.prank(alice);
        (,, liq) = pool.addLiquidity{value: SEED_ETH}(SEED_SQK, 0, 0, alice, block.timestamp);
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut, uint256 fee) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * (10_000 - fee);
        return inWithFee * rOut / (rIn * 10_000 + inWithFee);
    }

    function _k() internal view returns (uint256) {
        (uint112 rS, uint112 rE,) = pool.getReserves();
        return uint256(rS) * uint256(rE);
    }

    // ------------------------------------------------------------ liquidity

    function test_firstMint_sqrtMinusMinimum() public {
        uint256 liq = _seed();
        uint256 expected = _sqrt(SEED_SQK * SEED_ETH) - pool.MINIMUM_LIQUIDITY();
        assertEq(liq, expected);
        assertEq(pool.balanceOf(alice), expected);
        assertEq(pool.balanceOf(address(0)), pool.MINIMUM_LIQUIDITY());
        (uint112 rS, uint112 rE,) = pool.getReserves();
        assertEq(rS, SEED_SQK);
        assertEq(rE, SEED_ETH);
    }

    function test_addLiquidity_proRata_refundsExcessETH() public {
        uint256 liq0 = _seed();
        uint256 before = bob.balance;
        vm.prank(bob);
        (uint256 aS, uint256 aE, uint256 liq) = pool.addLiquidity{value: 2 ether}(1_000e18, 0, 0, bob, block.timestamp);
        assertEq(aS, 1_000e18);
        assertEq(aE, 1 ether, "ETH optimal at 1000:1 ratio");
        assertEq(before - bob.balance, 1 ether, "excess refunded");
        // pro-rata share: 10% of the pool → 10% of (liq0 + MINIMUM)
        assertEq(liq, (liq0 + pool.MINIMUM_LIQUIDITY()) / 10);
    }

    function test_addLiquidity_ethLimited_scalesSQKDown() public {
        _seed();
        vm.prank(bob);
        (uint256 aS, uint256 aE,) = pool.addLiquidity{value: 0.5 ether}(1_000e18, 0, 0, bob, block.timestamp);
        assertEq(aE, 0.5 ether);
        assertEq(aS, 500e18);
    }

    function test_addLiquidity_slippageReverts() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(WheelSwap.Slippage.selector);
        pool.addLiquidity{value: 0.5 ether}(1_000e18, 600e18, 0, bob, block.timestamp);
    }

    function test_removeLiquidity_proRata() public {
        uint256 liq = _seed();
        uint256 supply = pool.totalSupply();
        uint256 half = liq / 2;
        uint256 ethBefore = alice.balance;
        uint256 sqkBefore = sqk.balanceOf(alice);
        vm.prank(alice);
        (uint256 aS, uint256 aE) = pool.removeLiquidity(half, 0, 0, alice, block.timestamp);
        assertEq(aS, half * SEED_SQK / supply);
        assertEq(aE, half * SEED_ETH / supply);
        assertEq(alice.balance - ethBefore, aE);
        assertEq(sqk.balanceOf(alice) - sqkBefore, aS);
        assertEq(pool.balanceOf(alice), liq - half);
    }

    function test_removeLiquidity_slippageReverts() public {
        uint256 liq = _seed();
        vm.prank(alice);
        vm.expectRevert(WheelSwap.Slippage.selector);
        pool.removeLiquidity(liq, SEED_SQK, 0, alice, block.timestamp);
    }

    // ------------------------------------------------------------ swaps

    function test_swapETHForSQK_matchesFormula_napFee() public {
        _seed();
        uint256 expected = _out(1 ether, SEED_ETH, SEED_SQK, 50);
        uint256 before = sqk.balanceOf(bob);
        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit Swap(bob, 0, 1 ether, expected, 0, 50, WheelSwap.Wheel.NAP, bob);
        uint256 out = pool.swapExactETHForSQK{value: 1 ether}(0, bob, block.timestamp);
        assertEq(out, expected);
        assertEq(sqk.balanceOf(bob) - before, expected);
        (uint112 rS, uint112 rE,) = pool.getReserves();
        assertEq(rE, SEED_ETH + 1 ether);
        assertEq(rS, SEED_SQK - expected);
    }

    function test_swapSQKForETH_matchesFormula() public {
        _seed();
        uint256 expected = _out(500e18, SEED_SQK, SEED_ETH, 50);
        uint256 before = bob.balance;
        vm.prank(bob);
        uint256 out = pool.swapExactSQKForETH(500e18, 0, bob, block.timestamp);
        assertEq(out, expected);
        assertEq(bob.balance - before, expected);
    }

    function test_swap_minOutReverts() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(WheelSwap.InsufficientOutput.selector);
        pool.swapExactETHForSQK{value: 1 ether}(type(uint256).max, bob, block.timestamp);
    }

    function test_swap_deadlineReverts() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(WheelSwap.Expired.selector);
        pool.swapExactETHForSQK{value: 1 ether}(0, bob, block.timestamp - 1);
    }

    function test_swap_emptyPoolReverts() public {
        vm.prank(bob);
        vm.expectRevert(WheelSwap.InsufficientLiquidity.selector);
        pool.swapExactETHForSQK{value: 1 ether}(0, bob, block.timestamp);
    }

    function test_quoteSwap_matchesSwap() public {
        _seed();
        (uint256 q, uint16 fee, WheelSwap.Wheel w) = pool.quoteSwap(0.3 ether, false);
        assertEq(fee, 50);
        assertEq(uint8(w), uint8(WheelSwap.Wheel.NAP));
        vm.prank(bob);
        uint256 out = pool.swapExactETHForSQK{value: 0.3 ether}(0, bob, block.timestamp);
        assertEq(out, q);
    }

    // ------------------------------------------------------------ wheel → fee

    function test_fee_jog_whenWorkBelowPace() public {
        _seed();
        core.addBlocks(1_000);
        core.addWork(4_000); // 4000 per 1000 blocks < 8000
        (, uint16 fee,,,) = pool.currentWheel();
        assertEq(fee, 30);
        uint256 expected = _out(1 ether, SEED_ETH, SEED_SQK, 30);
        vm.prank(bob);
        uint256 out = pool.swapExactETHForSQK{value: 1 ether}(0, bob, block.timestamp);
        assertEq(out, expected);
        assertEq(uint8(pool.lastWheel()), uint8(WheelSwap.Wheel.JOG));
        assertEq(pool.lastHeight(), 1_100);
        assertEq(pool.lastWork(), 5_000);
    }

    function test_fee_zoomies_whenWorkAtPace() public {
        _seed();
        core.addBlocks(1_000);
        core.addWork(8_000); // exactly at difficulty → zoomies
        vm.prank(bob);
        uint256 out = pool.swapExactETHForSQK{value: 1 ether}(0, bob, block.timestamp);
        assertEq(out, _out(1 ether, SEED_ETH, SEED_SQK, 10));
        assertEq(uint8(pool.lastWheel()), uint8(WheelSwap.Wheel.ZOOMIES));
    }

    function test_fee_nap_whenBlocksButNoWork() public {
        _seed();
        core.addBlocks(1_000);
        core.addWork(9_000);
        vm.prank(bob);
        pool.swapExactETHForSQK{value: 0.1 ether}(0, bob, block.timestamp); // → zoomies
        core.addBlocks(500); // hamster slept: blocks, no work
        (WheelSwap.Wheel w, uint16 fee,,,) = pool.currentWheel();
        assertEq(uint8(w), uint8(WheelSwap.Wheel.NAP));
        assertEq(fee, 50);
    }

    function test_wheel_sticky_untilNewHeight() public {
        _seed();
        core.addBlocks(1_000);
        core.addWork(9_000);
        vm.prank(bob);
        pool.swapExactETHForSQK{value: 0.1 ether}(0, bob, block.timestamp); // observes zoomies
        core.addWork(1); // work but no settled block yet → classification sticks
        (WheelSwap.Wheel w, uint16 fee,,,) = pool.currentWheel();
        assertEq(uint8(w), uint8(WheelSwap.Wheel.ZOOMIES));
        assertEq(fee, 10);
    }

    function test_wheel_tracksStretchNotLifetime() public {
        _seed();
        core.addBlocks(1_000);
        core.addWork(20_000); // huge first stretch
        vm.prank(bob);
        pool.swapExactETHForSQK{value: 0.1 ether}(0, bob, block.timestamp);
        core.addBlocks(1_000);
        core.addWork(100); // slow second stretch → jog, despite big lifetime average
        (WheelSwap.Wheel w,,,,) = pool.currentWheel();
        assertEq(uint8(w), uint8(WheelSwap.Wheel.JOG));
    }

    // ------------------------------------------------------------ invariants

    function testFuzz_swap_kNeverDecreases(uint96 amountIn, bool sqkIn) public {
        _seed();
        amountIn = uint96(bound(amountIn, 1e9, sqkIn ? 100_000e18 : 50 ether));
        uint256 kBefore = _k();
        vm.prank(bob);
        if (sqkIn) pool.swapExactSQKForETH(amountIn, 0, bob, block.timestamp);
        else pool.swapExactETHForSQK{value: amountIn}(0, bob, block.timestamp);
        assertGe(_k(), kBefore);
    }

    function testFuzz_addRemove_neverExtracts(uint128 amountSQK, uint128 amountETH) public {
        _seed();
        amountSQK = uint128(bound(amountSQK, 1e12, 500_000e18));
        amountETH = uint128(bound(amountETH, 1e9, 90 ether));
        uint256 s0 = sqk.balanceOf(bob);
        uint256 e0 = bob.balance;
        vm.startPrank(bob);
        (,, uint256 liq) = pool.addLiquidity{value: amountETH}(amountSQK, 0, 0, bob, block.timestamp);
        pool.removeLiquidity(liq, 0, 0, bob, block.timestamp);
        vm.stopPrank();
        assertLe(sqk.balanceOf(bob), s0);
        assertLe(bob.balance, e0);
    }

    function test_twap_accumulates() public {
        _seed();
        uint256 c0 = pool.priceETHCumulativeLast();
        vm.warp(block.timestamp + 100);
        vm.prank(bob);
        pool.swapExactETHForSQK{value: 0.01 ether}(0, bob, block.timestamp);
        uint256 expected = (uint256(uint224(SEED_SQK) << 112) / SEED_ETH) * 100;
        assertEq(pool.priceETHCumulativeLast() - c0, expected);
    }

    // ------------------------------------------------------------ permit, housekeeping, LP token

    function test_addLiquidityWithPermit_noPriorApproval() public {
        _seed();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                sqk.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(sqk.PERMIT_TYPEHASH(), carol, address(pool), 1_000e18, 0, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, digest);
        assertEq(sqk.allowance(carol, address(pool)), 0);
        vm.prank(carol);
        (uint256 aS,, uint256 liq) =
            pool.addLiquidityWithPermit{value: 1 ether}(1_000e18, 0, 0, carol, deadline, v, r, s);
        assertEq(aS, 1_000e18);
        assertGt(liq, 0);
        assertEq(sqk.nonces(carol), 1);
    }

    function test_swapWithPermit() public {
        _seed();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                sqk.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(sqk.PERMIT_TYPEHASH(), carol, address(pool), 100e18, 0, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(carolPk, digest);
        vm.prank(carol);
        uint256 out = pool.swapExactSQKForETHWithPermit(100e18, 0, carol, deadline, v, r, s);
        assertEq(out, _out(100e18, SEED_SQK, SEED_ETH, 50));
    }

    function test_skim_returnsDonations_sync_foldsThem() public {
        _seed();
        vm.prank(bob);
        sqk.transfer(address(pool), 123e18);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        uint256 s0 = sqk.balanceOf(bob);
        uint256 e0 = bob.balance;
        pool.skim(bob);
        assertEq(sqk.balanceOf(bob) - s0, 123e18);
        assertEq(bob.balance - e0, 1 ether);

        vm.prank(bob);
        sqk.transfer(address(pool), 7e18);
        pool.sync();
        (uint112 rS,,) = pool.getReserves();
        assertEq(rS, SEED_SQK + 7e18);
    }

    function test_reentrancyBlocked() public {
        _seed();
        Reenterer r = new Reenterer(payable(address(pool)));
        vm.deal(address(r), 1 ether);
        vm.prank(bob);
        sqk.transfer(address(r), 1_000e18);
        vm.prank(address(r));
        sqk.approve(address(pool), type(uint256).max);
        r.arm();
        vm.prank(address(r));
        vm.expectRevert(WheelSwap.EthSendFailed.selector);
        pool.swapExactSQKForETH(100e18, 0, address(r), block.timestamp);
    }

    function test_lpToken_transferAndAllowance() public {
        uint256 liq = _seed();
        vm.prank(alice);
        pool.approve(bob, liq);
        vm.prank(bob);
        pool.transferFrom(alice, bob, liq / 3);
        assertEq(pool.balanceOf(bob), liq / 3);
        assertEq(pool.allowance(alice, bob), liq - liq / 3);
        vm.prank(bob);
        vm.expectRevert(WheelSwap.InsufficientBalance.selector);
        pool.transfer(alice, liq);
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(WheelSwap.ZeroAddress.selector);
        new WheelSwap(address(0), address(sqk));
    }

    function test_gas_swap_underBudget() public {
        _seed();
        core.addBlocks(10);
        core.addWork(50);
        vm.prank(bob);
        uint256 g = gasleft();
        pool.swapExactETHForSQK{value: 0.2 ether}(0, bob, block.timestamp);
        assertLt(g - gasleft(), 120_000);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
