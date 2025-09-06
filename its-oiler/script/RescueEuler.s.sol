// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

// ---- Minimal interfaces ----
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
}

interface IEuler {
    // Euler core has module registry by moduleId; we’ll use known ids
    function moduleIdToProxy(uint256 moduleId) external view returns (address);
}
interface IMarkets {
    function underlyingToEToken(address underlying) external view returns (address);
    function underlyingToDToken(address underlying) external view returns (address);
    function enterMarket(uint256 subAccountId, address newMarket) external;
}
interface IEtoken {
    function balanceOf(address) external view returns (uint256);
    function underlyingAsset() external view returns (address); // some builds expose this; fallback to lens if missing
    function totalSupply() external view returns (uint256);
    // Euler eTokens use subaccounts; use 0 for primary
    function withdraw(uint256 subAccountId, uint256 amount) external;
    function convertBalanceToUnderlying(uint256 eBalance) external view returns (uint256); // if available
}
interface IDtoken {
    function borrow(uint256 subAccountId, uint256 amount) external;
}

interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ICurve3Pool {
    // exchange(i,j,dx, min_dy)
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}

contract RescueEulerScript {
    // --- Constants ---
    address constant EULER_MAIN = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // module ids from Euler v1 (public source)
    uint256 constant MODULEID__MARKETS = 2; // Markets module id
    // (If your fork differs, read the module ids from source or expose via your helper)

    address immutable me; // your address (holds 4.7k eWETH)
    constructor(address _me) {
        me = _me;
    }

    // Tokens
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI   = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Routers
    address constant UNI_V3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant CURVE3 = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // Helpers
    function _dec(address t) internal view returns (uint8) { try IERC20(t).decimals() returns (uint8 d) { return d; } catch { return 18; } }

    // --- Resolve Euler markets / tokens ---
    function _mkts() internal view returns (IMarkets) {
        address markets = IEuler(EULER_MAIN).moduleIdToProxy(MODULEID__MARKETS);
        require(markets != address(0), "Markets=0");
        return IMarkets(markets);
    }

    function _et(address underlying) internal view returns (IEtoken) {
        address e = _mkts().underlyingToEToken(underlying);
        require(e != address(0), "eToken=0");
        return IEtoken(e);
    }
    function _dt(address underlying) internal view returns (IDtoken) {
        address d = _mkts().underlyingToDToken(underlying);
        require(d != address(0), "dToken=0");
        return IDtoken(d);
    }

    function activateAll() external {
        IMarkets m = _mkts();
        m.enterMarket(0, WETH); // collateral
        m.enterMarket(0, USDC); // borrow markets
        m.enterMarket(0, DAI);
        m.enterMarket(0, USDT);
    }

    // --- Step A: Try to withdraw any remaining WETH reserves ---
    function withdrawWethReserves() public {
        IEtoken eWETH = _et(WETH);

        // Your eToken balance -> attempt to convert to underlying if function exists,
        // otherwise approximate pro-rata by pool’s totalSupply vs underlying cash.
        uint256 eBal = eWETH.balanceOf(address(this));
        require(eBal > 0, "no eWETH");

        uint256 claimUnderlying;
        try eWETH.convertBalanceToUnderlying(eBal) returns (uint256 u) {
            claimUnderlying = u;
        } catch {
            // fallback approx: pro-rata on remaining cash
            uint256 cash = IERC20(WETH).balanceOf(address(eWETH));
            uint256 ts = eWETH.totalSupply();
            claimUnderlying = ts == 0 ? 0 : (cash * eBal) / ts;
        }

        uint256 cashAvail = IERC20(WETH).balanceOf(address(eWETH));
        uint256 amt = claimUnderlying < cashAvail ? claimUnderlying : cashAvail;
        if (amt > 0) {
            // subAccountId = 0
            eWETH.withdraw(0, amt);
        }
    }

    // --- Step B: Borrow stables greedily (USDC, then DAI, then USDT) ---
    function _borrowMax(address underlying, uint256 maxTries) internal {
        IDtoken d = _dt(underlying);
        IMarkets m = _mkts();

        // Ensure collateral is enabled
        m.enterMarket(0, WETH);

        // Pool cash = what you can physically drain at most
        uint256 poolCash = IERC20(underlying).balanceOf(address(_et(underlying)));
        if (poolCash == 0) return;

        // Greedy geometric probing up to pool cash (protect against revert)
        uint256 step = poolCash / 2;
        if (step == 0) step = poolCash;

        uint256 borrowed = 0;
        for (uint256 i = 0; i < maxTries && borrowed < poolCash; i++) {
            uint256 tryAmt = borrowed + step <= poolCash ? step : (poolCash - borrowed);
            // try/catch to avoid revert bombing
            (bool ok,) = address(d).call(abi.encodeWithSelector(IDtoken.borrow.selector, uint256(0), tryAmt));
            if (ok) {
                borrowed += tryAmt;
                // keep step size
            } else {
                // back off
                if (step <= 1) break;
                step = step / 2;
            }
        }
    }

    function borrowStables() public {
        _borrowMax(USDC, 24);
        _borrowMax(DAI, 24);
        _borrowMax(USDT, 24);
        // add more stables if your fork shows liquidity (FRAX, LUSD) by repeating _borrowMax
    }

    // --- Step C: Swap everything to USDC ---
    function _swapUniV3WethToUsdc(uint24 fee) internal {
        uint256 amtIn = IERC20(WETH).balanceOf(address(this));
        if (amtIn == 0) return;
        IERC20(WETH).approve(UNI_V3, amtIn);
        IUniV3Router(UNI_V3).exactInputSingle(
            IUniV3Router.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: fee,                // try 500 first, fallback to 3000 if shallow
                recipient: address(this),
                deadline: block.timestamp + 600,
                amountIn: amtIn,
                amountOutMinimum: 0,     // fork sim: slippage not needed
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapCurve3(address tokenIn, int128 i, int128 j) internal {
        uint256 amt = IERC20(tokenIn).balanceOf(address(this));
        if (amt == 0) return;
        IERC20(tokenIn).approve(CURVE3, amt);
        ICurve3Pool(CURVE3).exchange(i, j, amt, 0);
    }

    function dumpAllToUSDC() public {
        // WETH -> USDC
        _swapUniV3WethToUsdc(500);
        if (IERC20(WETH).balanceOf(me) > 0) _swapUniV3WethToUsdc(3000);

        // DAI -> USDC (3pool: i=0 -> j=1)
        _swapCurve3(DAI, 0, 1);

        // USDT -> USDC (3pool: i=2 -> j=1)
        _swapCurve3(USDT, 2, 1);
    }

    function sweepUSDC() external {
        uint256 amt = IERC20(USDC).balanceOf(address(this));
        require(amt > 0, "no USDC");
        bool ok = IERC20(USDC).transfer(me, amt);
        require(ok, "transfer failed");
    }

    // --- Run full plan in 3 txs (recommended) ---
    // If your runner batches, you can call sequentially; otherwise call one-by-one:
    function runA_withdraw() external { withdrawWethReserves(); }
    function runB_borrow()   external { borrowStables(); }
    function runC_dump()     external { dumpAllToUSDC(); }
}
