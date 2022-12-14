pragma solidity 0.6.6;

import "./IKyberSanity.sol";
import "@kyber.network/utils-sc/contracts/Utils.sol";
import "@kyber.network/utils-sc/contracts/Withdrawable.sol";
import "@kyber.network/utils-sc/contracts/IERC20Ext.sol";

/**
 *   @title SanityRatesGasPrice contract
 *   The contract provides the following functionality:
 *       - setting reasonable diff
 *       - setting max gas price criteria for a trade
 *       - setting sanity rates
 *       - getting sanity rates
 *
 *   This allows FPR managers to protect their price updates from
 *   front runners by setting the maxGasPriceWei param. But it mainly
 *   protects reserves from (1) bugs in the conversion rate logic or
 *   from (2) hacks into the conversion rate system. If there are large
 *   inconsistencies between the sanity rates and the actual rates,
 *   then trades involving the reserve will be disabled.
 */

contract SanityRatesGasPriceVBSC is IKyberSanity, Withdrawable, Utils {
    struct SanityData {
        uint128 tokenRate;
        uint128 reasonableDiffInBps;
    }

    mapping(address => SanityData) public sanityData;
    uint256 public maxGasPriceWei;
    IERC20Ext public immutable quoteToken;

    event SanityMaxGasPriceSet(uint256 maxGasPrice);

    constructor(
        address _admin,
        uint256 _maxGasPriceWei,
        IERC20Ext _quoteToken
    ) public Withdrawable(_admin) {
        quoteToken = _quoteToken;
        setGasPrice(_maxGasPriceWei);
    }

    /// @dev set reasonableDiffInBps of a token to MAX_RATE to avoid handling the
    ///      price feed for this token
    function setReasonableDiff(
        IERC20Ext[] calldata srcs,
        uint256[] calldata diff
    ) external onlyAdmin {
        require(srcs.length == diff.length, "srcs,diff length mismatch");
        for (uint256 i = 0; i < srcs.length; i++) {
            require(
                diff[i] <= BPS || diff[i] == MAX_RATE,
                "Diff must be <= 10000 BPS or == MAX_RATE"
            );
            sanityData[address(srcs[i])].reasonableDiffInBps = uint128(diff[i]);
        }
    }

    function setMaxGasPriceWei(uint256 _maxGasPriceWei) external onlyOperator {
        setGasPrice(_maxGasPriceWei);
        emit SanityMaxGasPriceSet(maxGasPriceWei);
    }

    function setSanityRates(IERC20Ext[] calldata srcs, uint256[] calldata rates)
        external
        onlyOperator
    {
        require(srcs.length == rates.length, "srcs,rates length mismatch");

        for (uint256 i = 0; i < srcs.length; i++) {
            require(
                rates[i] > 0 && rates[i] <= MAX_RATE,
                "rate must be > 0 and <= MAX_RATE"
            );
            sanityData[address(srcs[i])].tokenRate = uint128(rates[i]);
        }
    }

    function getSanityRate(IERC20Ext src, IERC20Ext dest)
        external
        view
        override
        returns (uint256 rate)
    {
        SanityData memory data;

        if (src != quoteToken && dest != quoteToken) return 0;
        if (tx.gasprice > maxGasPriceWei) return 0;

        uint128 reasonableDiffInBps;
        if (src == quoteToken) {
            data = sanityData[address(dest)];
            reasonableDiffInBps = data.reasonableDiffInBps;
            rate = data.tokenRate > 0
                ? (PRECISION * PRECISION) / data.tokenRate
                : 0;
        } else {
            data = sanityData[address(src)];
            reasonableDiffInBps = data.reasonableDiffInBps;
            rate = data.tokenRate;
        }

        if (reasonableDiffInBps == MAX_RATE) return MAX_RATE;

        return (rate * (BPS + data.reasonableDiffInBps)) / BPS;
    }

    function setGasPrice(uint256 _maxGasPriceWei) internal {
        require(_maxGasPriceWei > 0, "maxGasPriceWei must be > 0");
        maxGasPriceWei = _maxGasPriceWei;
    }
}
