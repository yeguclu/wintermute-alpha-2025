// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IFlashLoanRecipient.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";

// ---------- Curve Controller ----------
interface IController {
  function liquidate(address user, uint256 min_x) external;
  function liquidate_extended(
      address user,
      uint256 min_x,
      uint256 frac,              // 1e18 = 100%
      bool use_eth,              // false for CRV collateral
      address callbacker,        // address(0) for no callback
      uint256[] memory args      // empty for no callback
  ) external;

  function borrowed_token() external view returns (address);
  function collateral_token() external view returns (address);

  // Amount of stable needed to liquidate `frac`
  function tokens_to_liquidate(address user, uint256 frac) external view returns (uint256);

  // [collateral, stable, debt, N]
  function user_state(address user) external view returns (uint256[4] memory);
}

// ---------- Curve pools ----------
interface ICurvePoolInt128 {
  function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}
interface ICurvePoolUint256 {
  function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

// ---------- Uniswap v3 ----------
interface ISwapRouter {
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

contract FlashLoanRecipient is IFlashLoanRecipient {
  // ---------- Events for diagnosis ----------
  event PreRepayBalances(uint256 usdc, uint256 crvUSD, uint256 crv, uint256 owe, uint256 frac);
  event SoldChunk(uint256 crvSold, uint256 usdcAfter, uint256 crvUsdAfter, uint256 wethAfter);

  // ---------- Addresses (mainnet) ----------
  IVault      private constant BAL_VAULT  = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
  IController public  constant CTRL       = IController(0xEdA215b7666936DEd834f76f3fBC6F323295110A);

  IERC20      public  constant CRV        = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
  IERC20      public  constant CRVUSD     = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
  IERC20      public  constant USDC       = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
  IERC20      public  constant WETH       = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  ISwapRouter public  constant UNIV3      = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

  // Curve pools
  ICurvePoolInt128  public  constant CRVUSD_USDC_POOL = ICurvePoolInt128(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E); // (USDC,crvUSD)
  ICurvePoolUint256 public  constant TRICRV_POOL      = ICurvePoolUint256(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14); // (crvUSD,WETH,CRV)

  // Indices
  int128  constant USDC_INDEX        = 0; // in crvUSD/USDC
  int128  constant CRVUSD_INDEX      = 1; // in crvUSD/USDC
  uint256 constant TRI_CRVUSD_INDEX  = 0; // in triCRV
  uint256 constant TRI_WETH_INDEX    = 1; // in triCRV
  uint256 constant TRI_CRV_INDEX     = 2; // in triCRV

  // Uni v3 fee tier for WETH/USDC
  uint24  constant FEE_WETH_USDC     = 500; // 0.05%

  // Exposed exploiter (you can parameterize via userData if needed)
  address public constant EXPLOITER   = 0x6F8C5692b00c2eBbd07e4FD80E332DfF3ab8E83c;

  // ---------- Admin ----------
  address public owner;
  address public beneficiary;

  modifier onlyOwner() {
    require(msg.sender == owner, "only owner");
    _;
  }

  constructor() {
    owner = msg.sender;
    beneficiary = 0x48008aA5B9CA70EeFe7d1348bB2b7C3094426AA6;
  }

  function setBeneficiary(address to) external onlyOwner {
    beneficiary = to;
  }

  // ---------- Entrypoint ----------
  // userData = abi.encode(uint256 frac)
  function makeFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, bytes memory userData)
    external
    onlyOwner
  {
    require(tokens.length == 1 && address(tokens[0]) == address(USDC), "flash USDC only");
    require(amounts.length == 1 && amounts[0] > 0, "amount?");
    BAL_VAULT.flashLoan(this, tokens, amounts, userData);
  }

  // ---------- Balancer callback ----------
  function receiveFlashLoan(
    IERC20[] calldata tokens,
    uint256[] calldata amounts,
    uint256[] calldata feeAmounts,
    bytes calldata userData
  ) external override {
    require(msg.sender == address(BAL_VAULT), "bad caller");
    require(tokens.length == 1 && address(tokens[0]) == address(USDC), "token!=USDC");

    uint256 amt = amounts[0];
    uint256 fee = feeAmounts[0];
    require(fee == 0, "no fee?");
    uint256 owe = amt + fee;

    // Decode the liquidation fraction; default to 20% if empty
    uint256 frac = 1e16; // 1/100

    // Query how much crvUSD the controller needs for this fraction
    uint256 needCrvUsd = CTRL.tokens_to_liquidate(EXPLOITER, frac); // 18d
    // Convert target to USDC base (6d) with a tiny +0.3% buffer
    uint256 needUsdc = (needCrvUsd + 1e12 - 1) / 1e12;    // ceil(18d->6d)
    needUsdc = (needUsdc * 1003) / 1000;

    // Cap by flash amount
    if (needUsdc > amt) needUsdc = amt;

    // 1) Swap USDC -> crvUSD just for what we need
    if (needUsdc > 0) {
      USDC.approve(address(CRVUSD_USDC_POOL), needUsdc);
      CRVUSD_USDC_POOL.exchange(USDC_INDEX, CRVUSD_INDEX, needUsdc, 0);
    }

    // 2) Partial liquidation
    CRVUSD.approve(address(CTRL), CRVUSD.balanceOf(address(this)));
    CTRL.liquidate_extended(
      EXPLOITER,
      0,           // min_x
      frac,        // fraction (1e18 = 100%)
      false,       // use_eth=false (collateral is CRV)
      address(0),  // no callback
      new uint256[](0)
    );

    // 3) Convert any leftover crvUSD back to USDC
    uint256 crvUsdLeft = CRVUSD.balanceOf(address(this));
    if (crvUsdLeft > 0) {
      CRVUSD.approve(address(CRVUSD_USDC_POOL), crvUsdLeft);
      CRVUSD_USDC_POOL.exchange(CRVUSD_INDEX, USDC_INDEX, crvUsdLeft, 0);
    }

    // 4) If still short: sell minimal CRV chunks across both routes until we cover 'owe'
    _sellCrvEnoughToCover(owe);

    // Emit pre-repay snapshot so you can inspect TX logs
    emit PreRepayBalances(USDC.balanceOf(address(this)), CRVUSD.balanceOf(address(this)), CRV.balanceOf(address(this)), owe, frac);

    // 5) Repay Balancer by transfer
    uint256 haveUsdc = USDC.balanceOf(address(this));
    USDC.transfer(address(BAL_VAULT), owe);

    // 6) CRV profit → beneficiary
    uint256 crvProfit = CRV.balanceOf(address(this));
    if (crvProfit > 0) {
      CRV.transfer(beneficiary, crvProfit);
    }
  }

  // ---------- Helpers ----------
  // Sell CRV in small slices until we reach 'owe'
  function _sellCrvEnoughToCover(uint256 owe) internal {
    uint256 haveUsdc = USDC.balanceOf(address(this));
    if (haveUsdc >= owe) return;

    uint256 maxBatches = 1;               // small, repeated sells
    uint256 sliceBps   = 10000;              // 8% of current CRV per batch (adjust as needed)
    for (uint256 i = 0; i < maxBatches; i++) {
      uint256 crvBal = CRV.balanceOf(address(this));
      if (crvBal == 0) break;

      uint256 toSell = (crvBal * sliceBps) / 10000;
      if (toSell == 0) toSell = crvBal;    // last dust

      // Split half to crvUSD path, half to WETH path
      uint256 half  = toSell / 2;
      uint256 other = toSell - half;

      if (half > 0) {
        CRV.approve(address(TRICRV_POOL), half);
        TRICRV_POOL.exchange(TRI_CRV_INDEX, TRI_CRVUSD_INDEX, half, 0);
      }
      // crvUSD -> USDC
      uint256 crvUsdNow = CRVUSD.balanceOf(address(this));
      if (crvUsdNow > 0) {
        CRVUSD.approve(address(CRVUSD_USDC_POOL), crvUsdNow);
        CRVUSD_USDC_POOL.exchange(CRVUSD_INDEX, USDC_INDEX, crvUsdNow, 0);
      }

      if (other > 0) {
        CRV.approve(address(TRICRV_POOL), other);
        TRICRV_POOL.exchange(TRI_CRV_INDEX, TRI_WETH_INDEX, other, 0);
      }
      // WETH -> USDC (Uni v3 0.05%)
      uint256 wethBal = WETH.balanceOf(address(this));
      if (wethBal > 0) {
        WETH.approve(address(UNIV3), wethBal);
        UNIV3.exactInputSingle(
          ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(USDC),
            fee: FEE_WETH_USDC,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: wethBal,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
          })
        );
      }

      emit SoldChunk(toSell, USDC.balanceOf(address(this)), CRVUSD.balanceOf(address(this)), WETH.balanceOf(address(this)));

      if (USDC.balanceOf(address(this)) >= owe) break;
    }
  }

  function withdraw() external onlyOwner {
    uint256 usdcBal = USDC.balanceOf(address(this));
    require(usdcBal > 0, "no USDC");

    uint256 half  = usdcBal / 2;
    uint256 other = usdcBal - half;

    // USDC -> crvUSD (Curve crvUSD/USDC pool, int128 indices)
    uint256 crvUsdBought = 0;
    if (half > 0) {
        USDC.approve(address(CRVUSD_USDC_POOL), half);
        // min_dy = 0 for the challenge; add a safety min if you want
        crvUsdBought = CRVUSD_USDC_POOL.exchange(USDC_INDEX, CRVUSD_INDEX, half, 0);
    }

    // USDC -> WETH (Uniswap v3 0.05%)
    uint256 wethBought = 0;
    if (other > 0) {
        USDC.approve(address(UNIV3), other);
        wethBought = UNIV3.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WETH),
                fee: FEE_WETH_USDC,          // 500 = 0.05%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: other,
                amountOutMinimum: 0,          // set a min if you want safety
                sqrtPriceLimitX96: 0
            })
        );
    }

    // crvUSD -> CRV (triCRV: 0 -> 2)
    uint256 crvUsdBal = CRVUSD.balanceOf(address(this));
    if (crvUsdBal > 0) {
        CRVUSD.approve(address(TRICRV_POOL), crvUsdBal);
        TRICRV_POOL.exchange(TRI_CRVUSD_INDEX, TRI_CRV_INDEX, crvUsdBal, 0);
    }

    // WETH -> CRV (triCRV: 1 -> 2)
    uint256 wethBal = WETH.balanceOf(address(this));
    if (wethBal > 0) {
        WETH.approve(address(TRICRV_POOL), wethBal);
        TRICRV_POOL.exchange(TRI_WETH_INDEX, TRI_CRV_INDEX, wethBal, 0);
    }

    // Send all CRV to beneficiary
    uint256 crvOut = CRV.balanceOf(address(this));
    require(crvOut > 0, "no CRV out");
    CRV.transfer(beneficiary, crvOut);
  }
}