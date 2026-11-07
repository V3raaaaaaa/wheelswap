// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISqueekCore, IERC20Permit} from "./interfaces/ISqueek.sol";

/// @title Wheelswap — the SQK/ETH pool paced by Squeektoshi's wheel
/// @notice A constant-product AMM (x·y = k) for SQK against native ETH on Sepolia, with one twist:
///         the swap fee is set by the real hamster. Before every swap the pool reads
///         `SqueekCore.state()` and classifies the stretch of Squeek blocks settled since it last
///         looked, measured against the live difficulty (`workPerThousandBlocks`):
///
///           NAP     — new blocks, no new work            → 0.50 %
///           JOG     — work below the difficulty pace     → 0.30 %
///           ZOOMIES — work at or above the difficulty pace → 0.10 %
///
///         Between settlements the last classification sticks. Every fee stays in the pool and
///         accrues to LP holders. There is no owner, no admin, no fee switch, no pause, no upgrade.
///
/// @dev    Single pool, router functions built in (no WETH, no factory). SQK is a plain OpenZeppelin
///         ERC-20 with EIP-2612 permit; received amounts are still measured by balance delta.
contract WheelSwap {
    // =============================================================
    //                           LP TOKEN
    // =============================================================

    string public constant name = "Wheelswap SQK-ETH LP";
    string public constant symbol = "wSQK-ETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // =============================================================
    //                             POOL
    // =============================================================

    ISqueekCore public immutable core;
    IERC20Permit public immutable sqk;

    uint256 public constant MINIMUM_LIQUIDITY = 1_000;
    uint16 public constant FEE_NAP_BPS = 50;
    uint16 public constant FEE_JOG_BPS = 30;
    uint16 public constant FEE_ZOOMIES_BPS = 10;
    uint256 private constant BPS = 10_000;

    uint112 private _reserveSQK;
    uint112 private _reserveETH;
    uint32 private _blockTimestampLast;

    /// @notice UQ112x112 price accumulators for TWAP consumers (Uniswap V2 semantics).
    uint256 public priceSQKCumulativeLast; // ETH per SQK
    uint256 public priceETHCumulativeLast; // SQK per ETH

    // =============================================================
    //                         WHEEL TRACKER
    // =============================================================

    enum Wheel {
        NAP,
        JOG,
        ZOOMIES
    }

    uint64 public lastWork; // cumulativeWork at the last observation
    uint64 public lastHeight; // Squeek blockHeight at the last observation
    Wheel public lastWheel; // classification of the last settled stretch

    bool private _locked;

    event Mint(address indexed sender, uint256 amountSQK, uint256 amountETH, uint256 liquidity, address indexed to);
    event Burn(address indexed sender, uint256 amountSQK, uint256 amountETH, uint256 liquidity, address indexed to);
    event Swap(
        address indexed sender,
        uint256 sqkIn,
        uint256 ethIn,
        uint256 sqkOut,
        uint256 ethOut,
        uint16 feeBps,
        Wheel wheel,
        address indexed to
    );
    event Sync(uint112 reserveSQK, uint112 reserveETH);
    event WheelObserved(uint64 work, uint64 height, uint32 difficulty, Wheel wheel);

    error Expired();
    error Reentrancy();
    error ZeroAddress();
    error InsufficientInput();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error Slippage();
    error Overflow();
    error TransferFailed();
    error EthSendFailed();
    error InsufficientAllowance();
    error InsufficientBalance();

    modifier lock() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address core_, address sqk_) {
        if (core_ == address(0) || sqk_ == address(0)) revert ZeroAddress();
        core = ISqueekCore(core_);
        sqk = IERC20Permit(sqk_);
        ISqueekCore.CoreState memory s = core.state();
        lastWork = s.cumulativeWork;
        lastHeight = s.blockHeight;
        lastWheel = Wheel.NAP;
    }

    // =============================================================
    //                             VIEWS
    // =============================================================

    function getReserves() public view returns (uint112 reserveSQK, uint112 reserveETH, uint32 blockTimestampLast) {
        return (_reserveSQK, _reserveETH, _blockTimestampLast);
    }

    /// @notice What the next swap would see: wheel class, fee, and the raw core numbers behind it.
    function currentWheel()
        public
        view
        returns (Wheel wheel, uint16 feeBps, uint64 work, uint64 height, uint32 difficulty)
    {
        ISqueekCore.CoreState memory s = core.state();
        work = s.cumulativeWork;
        height = s.blockHeight;
        difficulty = s.workPerThousandBlocks;
        wheel = _classify(work, height, difficulty);
        feeBps = _feeFor(wheel);
    }

    /// @notice Output for `amountIn` of SQK (sqkIn = true) or ETH (sqkIn = false) at the current wheel fee.
    function quoteSwap(uint256 amountIn, bool sqkIn)
        external
        view
        returns (uint256 amountOut, uint16 feeBps, Wheel wheel)
    {
        (wheel, feeBps,,,) = currentWheel();
        (uint112 rS, uint112 rE,) = getReserves();
        amountOut = sqkIn ? _getAmountOut(amountIn, rS, rE, feeBps) : _getAmountOut(amountIn, rE, rS, feeBps);
    }

    /// @notice ETH that pairs with `amountSQK` at the current reserve ratio (0 when the pool is empty).
    function quoteLiquidity(uint256 amountSQK) external view returns (uint256 amountETH) {
        (uint112 rS, uint112 rE,) = getReserves();
        if (rS == 0) return 0;
        amountETH = amountSQK * rE / rS;
    }

    // =============================================================
    //                           LIQUIDITY
    // =============================================================

    function addLiquidity(
        uint256 amountSQKDesired,
        uint256 amountSQKMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable lock ensure(deadline) returns (uint256 amountSQK, uint256 amountETH, uint256 liquidity) {
        return _addLiquidity(amountSQKDesired, amountSQKMin, amountETHMin, to);
    }

    /// @notice Same as `addLiquidity` but approves SQK in the same transaction via EIP-2612.
    function addLiquidityWithPermit(
        uint256 amountSQKDesired,
        uint256 amountSQKMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable lock ensure(deadline) returns (uint256 amountSQK, uint256 amountETH, uint256 liquidity) {
        sqk.permit(msg.sender, address(this), amountSQKDesired, deadline, v, r, s);
        return _addLiquidity(amountSQKDesired, amountSQKMin, amountETHMin, to);
    }

    function removeLiquidity(uint256 liquidity, uint256 amountSQKMin, uint256 amountETHMin, address to, uint256 deadline)
        external
        lock
        ensure(deadline)
        returns (uint256 amountSQK, uint256 amountETH)
    {
        if (to == address(0)) revert ZeroAddress();
        (uint112 rS, uint112 rE,) = getReserves();
        uint256 balS = sqk.balanceOf(address(this));
        uint256 balE = address(this).balance;
        uint256 supply = totalSupply;
        amountSQK = liquidity * balS / supply;
        amountETH = liquidity * balE / supply;
        if (amountSQK == 0 || amountETH == 0) revert InsufficientLiquidity();
        if (amountSQK < amountSQKMin || amountETH < amountETHMin) revert Slippage();

        _burn(msg.sender, liquidity);
        _update(balS - amountSQK, balE - amountETH, rS, rE);
        _pushSQK(to, amountSQK);
        _sendETH(to, amountETH);
        emit Burn(msg.sender, amountSQK, amountETH, liquidity, to);
    }

    // =============================================================
    //                             SWAPS
    // =============================================================

    function swapExactETHForSQK(uint256 amountOutMin, address to, uint256 deadline)
        external
        payable
        lock
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (to == address(0)) revert ZeroAddress();
        (Wheel wheel, uint16 fee) = _observeWheel();
        (uint112 rS, uint112 rE,) = getReserves();
        amountOut = _getAmountOut(msg.value, rE, rS, fee);
        if (amountOut < amountOutMin || amountOut == 0) revert InsufficientOutput();

        _update(uint256(rS) - amountOut, uint256(rE) + msg.value, rS, rE);
        _pushSQK(to, amountOut);
        emit Swap(msg.sender, 0, msg.value, amountOut, 0, fee, wheel, to);
    }

    function swapExactSQKForETH(uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline)
        external
        lock
        ensure(deadline)
        returns (uint256 amountOut)
    {
        return _swapSQKForETH(amountIn, amountOutMin, to);
    }

    /// @notice Same as `swapExactSQKForETH` but approves SQK in the same transaction via EIP-2612.
    function swapExactSQKForETHWithPermit(
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external lock ensure(deadline) returns (uint256 amountOut) {
        sqk.permit(msg.sender, address(this), amountIn, deadline, v, r, s);
        return _swapSQKForETH(amountIn, amountOutMin, to);
    }

    // =============================================================
    //                        BALANCE HOUSEKEEPING
    // =============================================================

    /// @notice Send any balance above the tracked reserves to `to` (tokens or ETH forced in).
    function skim(address to) external lock {
        if (to == address(0)) revert ZeroAddress();
        (uint112 rS, uint112 rE,) = getReserves();
        uint256 extraS = sqk.balanceOf(address(this)) - rS;
        uint256 extraE = address(this).balance - rE;
        if (extraS > 0) _pushSQK(to, extraS);
        if (extraE > 0) _sendETH(to, extraE);
    }

    /// @notice Fold any balance above the tracked reserves into the pool (a donation to LPs).
    function sync() external lock {
        (uint112 rS, uint112 rE,) = getReserves();
        _update(sqk.balanceOf(address(this)), address(this).balance, rS, rE);
    }

    // =============================================================
    //                        ERC-20 (LP TOKEN)
    // =============================================================

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    // =============================================================
    //                           INTERNALS
    // =============================================================

    function _addLiquidity(uint256 amountSQKDesired, uint256 amountSQKMin, uint256 amountETHMin, address to)
        private
        returns (uint256 amountSQK, uint256 amountETH, uint256 liquidity)
    {
        if (to == address(0)) revert ZeroAddress();
        (uint112 rS, uint112 rE,) = getReserves();

        if (rS == 0 && rE == 0) {
            amountSQK = amountSQKDesired;
            amountETH = msg.value;
        } else {
            uint256 ethOptimal = amountSQKDesired * rE / rS;
            if (ethOptimal <= msg.value) {
                if (ethOptimal < amountETHMin) revert Slippage();
                amountSQK = amountSQKDesired;
                amountETH = ethOptimal;
            } else {
                uint256 sqkOptimal = msg.value * rS / rE;
                if (sqkOptimal < amountSQKMin) revert Slippage();
                amountSQK = sqkOptimal;
                amountETH = msg.value;
            }
        }
        if (amountSQK == 0 || amountETH == 0) revert InsufficientInput();

        amountSQK = _pullSQK(msg.sender, amountSQK);

        uint256 supply = totalSupply;
        if (supply == 0) {
            liquidity = _sqrt(amountSQK * amountETH) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently locked, as in Uniswap V2
        } else {
            liquidity = _min(amountSQK * supply / rS, amountETH * supply / rE);
        }
        if (liquidity == 0) revert InsufficientLiquidity();
        _mint(to, liquidity);

        uint256 refund = msg.value - amountETH;
        _update(uint256(rS) + amountSQK, uint256(rE) + amountETH, rS, rE);
        if (refund > 0) _sendETH(msg.sender, refund);
        emit Mint(msg.sender, amountSQK, amountETH, liquidity, to);
    }

    function _swapSQKForETH(uint256 amountIn, uint256 amountOutMin, address to) private returns (uint256 amountOut) {
        if (to == address(0)) revert ZeroAddress();
        (Wheel wheel, uint16 fee) = _observeWheel();
        (uint112 rS, uint112 rE,) = getReserves();
        amountIn = _pullSQK(msg.sender, amountIn);
        amountOut = _getAmountOut(amountIn, rS, rE, fee);
        if (amountOut < amountOutMin || amountOut == 0) revert InsufficientOutput();

        _update(uint256(rS) + amountIn, uint256(rE) - amountOut, rS, rE);
        _sendETH(to, amountOut);
        emit Swap(msg.sender, amountIn, 0, 0, amountOut, fee, wheel, to);
    }

    /// @dev Classify the stretch since the last observation. No new Squeek blocks → keep the last class.
    function _classify(uint64 work, uint64 height, uint32 difficulty) private view returns (Wheel) {
        if (height <= lastHeight) return lastWheel;
        uint256 dWork = work > lastWork ? work - lastWork : 0;
        if (dWork == 0) return Wheel.NAP;
        uint256 pace = dWork * 1000 / (height - lastHeight); // work per 1000 Squeek blocks
        return pace >= difficulty ? Wheel.ZOOMIES : Wheel.JOG;
    }

    function _observeWheel() private returns (Wheel wheel, uint16 feeBps) {
        ISqueekCore.CoreState memory s = core.state();
        wheel = _classify(s.cumulativeWork, s.blockHeight, s.workPerThousandBlocks);
        if (s.blockHeight > lastHeight) {
            lastWork = s.cumulativeWork;
            lastHeight = s.blockHeight;
            lastWheel = wheel;
            emit WheelObserved(s.cumulativeWork, s.blockHeight, s.workPerThousandBlocks, wheel);
        }
        feeBps = _feeFor(wheel);
    }

    function _feeFor(Wheel w) private pure returns (uint16) {
        if (w == Wheel.ZOOMIES) return FEE_ZOOMIES_BPS;
        if (w == Wheel.JOG) return FEE_JOG_BPS;
        return FEE_NAP_BPS;
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint16 feeBps)
        private
        pure
        returns (uint256)
    {
        if (amountIn == 0) revert InsufficientInput();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 inWithFee = amountIn * (BPS - feeBps);
        return inWithFee * reserveOut / (reserveIn * BPS + inWithFee);
    }

    function _update(uint256 balS, uint256 balE, uint112 rS, uint112 rE) private {
        if (balS > type(uint112).max || balE > type(uint112).max) revert Overflow();
        uint32 ts = uint32(block.timestamp);
        uint32 elapsed;
        unchecked {
            elapsed = ts - _blockTimestampLast;
        }
        if (elapsed > 0 && rS != 0 && rE != 0) {
            unchecked {
                priceSQKCumulativeLast += uint256(_uq(rE, rS)) * elapsed;
                priceETHCumulativeLast += uint256(_uq(rS, rE)) * elapsed;
            }
        }
        _reserveSQK = uint112(balS);
        _reserveETH = uint112(balE);
        _blockTimestampLast = ts;
        emit Sync(uint112(balS), uint112(balE));
    }

    function _uq(uint112 num, uint112 den) private pure returns (uint224) {
        return (uint224(num) << 112) / den;
    }

    function _pullSQK(address from, uint256 amount) private returns (uint256 received) {
        uint256 before = sqk.balanceOf(address(this));
        if (!sqk.transferFrom(from, address(this), amount)) revert TransferFailed();
        received = sqk.balanceOf(address(this)) - before;
        if (received == 0) revert InsufficientInput();
    }

    function _pushSQK(address to, uint256 amount) private {
        if (!sqk.transfer(to, amount)) revert TransferFailed();
    }

    function _sendETH(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }

    function _mint(address to, uint256 value) private {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
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
