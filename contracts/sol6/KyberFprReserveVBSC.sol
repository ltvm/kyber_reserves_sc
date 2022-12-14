// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "./IKyberReserve.sol";
import "./IWeth.sol";
import "./IKyberSanity.sol";
import "./IConversionRates.sol";
import "@kyber.network/utils-sc/contracts/Utils.sol";
import "@kyber.network/utils-sc/contracts/Withdrawable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KyberFprReserve version 2
/// Allow Reserve to work work with either weth or eth.
/// for working with weth should specify external address to hold weth.
/// Allow Reserve to set maxGasPriceWei to trade with
contract KyberFprReserveVBSC is
    IKyberReserve,
    Utils,
    Withdrawable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20Ext;
    using SafeMath for uint256;

    mapping(bytes32 => bool) public approvedWithdrawAddresses; // sha3(token,address)=>bool
    mapping(address => address) public tokenWallet;

    struct ConfigData {
        bool tradeEnabled;
        uint128 maxGasPriceWei;
    }

    ConfigData internal configData;

    IConversionRates public conversionRatesContract;
    IKyberSanity public sanityRatesContract;
    IWeth public weth;
    IERC20Ext public immutable quoteToken;
    
    mapping(address=>bool) public whiteListAddr;

    modifier onlyWhitelist() {
        require(whiteListAddr[msg.sender], "not whitelist"); 
        _;
    }
    

    event DepositToken(IERC20Ext indexed token, uint256 amount);
    event TradeExecute(
        address origin,
        address indexed trader,
        IERC20Ext indexed src,
        uint256 srcAmount,
        IERC20Ext indexed destToken,
        uint256 destAmount,
        address payable destAddress
    );
    event TradeEnabled(bool enable);
    event MaxGasPriceUpdated(uint128 newMaxGasPrice);
    event WithdrawAddressApproved(
        IERC20Ext indexed token,
        address indexed addr,
        bool approve
    );
    event NewTokenWallet(IERC20Ext indexed token, address indexed wallet);
    event WithdrawFunds(
        IERC20Ext indexed token,
        uint256 amount,
        address indexed destination
    );
    event SetConversionRateAddress(IConversionRates indexed rate);
    event SetWethAddress(IWeth indexed weth);
    event SetSanityRateAddress(IKyberSanity indexed sanity);

    event WhiteListed(address user);
    event BlackListed(address user);

    constructor(
        IConversionRates _ratesContract,
        IWeth _weth,
        IERC20Ext _quoteToken,
        uint128 _maxGasPriceWei,
        address _admin
    ) public Withdrawable(_admin) {
        require(_ratesContract != IConversionRates(0), "ratesContract 0");
        require(_weth != IWeth(0), "weth 0");
        conversionRatesContract = _ratesContract;
        weth = _weth;
        quoteToken = _quoteToken;
        configData = ConfigData({
            tradeEnabled: true,
            maxGasPriceWei: _maxGasPriceWei
        });
    }

    receive() external payable {
        emit DepositToken(ETH_TOKEN_ADDRESS, msg.value);
    }

    function whiteList(address user) external onlyAdmin {
        require(!whiteListAddr[user], "address is already whitelist");
        whiteListAddr[user] = true;
        emit WhiteListed(user);
    }
    
    function blackList(address user) external onlyAdmin {
        require(whiteListAddr[user], "address is not on whitelist");
        whiteListAddr[user] = false;
        emit BlackListed(user);
    }

    function trade(
        IERC20Ext srcToken,
        uint256 srcAmount,
        IERC20Ext destToken,
        address payable destAddress,
        uint256 conversionRate,
        bool /* validate */
    ) public payable override onlyWhitelist nonReentrant returns (bool) {
        ConfigData memory data = configData;
        require(data.tradeEnabled, "trade not enable");
        require(
            tx.gasprice <= uint256(data.maxGasPriceWei),
            "gas price too high"
        );

        doTrade(srcToken, srcAmount, destToken, destAddress, conversionRate);

        return true;
    }

    function enableTrade() external onlyAdmin {
        configData.tradeEnabled = true;
        emit TradeEnabled(true);
    }

    function disableTrade() external onlyAlerter {
        configData.tradeEnabled = false;
        emit TradeEnabled(false);
    }

    function setMaxGasPrice(uint128 newMaxGasPrice) external onlyOperator {
        configData.maxGasPriceWei = newMaxGasPrice;
        emit MaxGasPriceUpdated(newMaxGasPrice);
    }

    function approveWithdrawAddress(
        IERC20Ext token,
        address addr,
        bool approve
    ) external onlyAdmin {
        approvedWithdrawAddresses[
            keccak256(abi.encodePacked(address(token), addr))
        ] = approve;
        getSetDecimals(token);
        emit WithdrawAddressApproved(token, addr, approve);
    }

    /// @dev allow set tokenWallet[token] back to 0x0 address
    /// @dev in case of using weth from external wallet, must call set token wallet for weth
    ///      tokenWallet for weth must be different from this reserve address
    function setTokenWallet(IERC20Ext token, address wallet)
        external
        onlyAdmin
    {
        tokenWallet[address(token)] = wallet;
        getSetDecimals(token);
        emit NewTokenWallet(token, wallet);
    }

    /// @dev withdraw amount of token to an approved destination
    ///      if reserve is using weth instead of eth, should call withdraw weth
    /// @param token token to withdraw
    /// @param amount amount to withdraw
    /// @param destination address to transfer fund to
    function withdraw(
        IERC20Ext token,
        uint256 amount,
        address destination
    ) external onlyOperator {
        require(
            approvedWithdrawAddresses[
                keccak256(abi.encodePacked(address(token), destination))
            ],
            "destination is not approved"
        );

        if (token == ETH_TOKEN_ADDRESS) {
            (bool success, ) = destination.call{value: amount}("");
            require(success, "withdraw eth failed");
        } else {
            address wallet = getTokenWallet(token);
            if (wallet == address(this)) {
                token.safeTransfer(destination, amount);
            } else {
                token.safeTransferFrom(wallet, destination, amount);
            }
        }

        emit WithdrawFunds(token, amount, destination);
    }

    function setConversionRate(IConversionRates _newConversionRate)
        external
        onlyAdmin
    {
        require(_newConversionRate != IConversionRates(0), "conversionRates 0");
        conversionRatesContract = _newConversionRate;
        emit SetConversionRateAddress(_newConversionRate);
    }

    /// @dev weth is unlikely to be changed, but added this function to keep the flexibilty
    function setWeth(IWeth _newWeth) external onlyAdmin {
        require(_newWeth != IWeth(0), "weth 0");
        weth = _newWeth;
        emit SetWethAddress(_newWeth);
    }

    /// @dev sanity rate can be set to 0x0 address to disable sanity rate check
    function setSanityRate(IKyberSanity _newSanity) external onlyAdmin {
        sanityRatesContract = _newSanity;
        emit SetSanityRateAddress(_newSanity);
    }

    function getConversionRate(
        IERC20Ext src,
        IERC20Ext dest,
        uint256 srcQty,
        uint256 blockNumber
    ) external view override returns (uint256) {
        ConfigData memory data = configData;
        if (!data.tradeEnabled) return 0;
        if (tx.gasprice > uint256(data.maxGasPriceWei)) return 0;
        if (srcQty == 0) return 0;

        IERC20Ext token;
        bool isBuy;

        if (quoteToken == src) {
            isBuy = true;
            token = dest;
        } else if (quoteToken == dest) {
            isBuy = false;
            token = src;
        } else {
            return 0; // pair is not listed
        }

        uint256 rate;
        try
            conversionRatesContract.getRate(token, blockNumber, isBuy, srcQty)
        returns (uint256 r) {
            rate = r;
        } catch {
            return 0;
        }
        uint256 destQty = calcDestAmount(src, dest, srcQty, rate);

        if (getBalance(dest) < destQty) return 0;

        if (sanityRatesContract != IKyberSanity(0)) {
            uint256 sanityRate = sanityRatesContract.getSanityRate(src, dest);
            if (rate > sanityRate) return 0;
        }

        return rate;
    }

    function isAddressApprovedForWithdrawal(IERC20Ext token, address addr)
        external
        view
        returns (bool)
    {
        return
            approvedWithdrawAddresses[
                keccak256(abi.encodePacked(address(token), addr))
            ];
    }

    function tradeEnabled() external view returns (bool) {
        return configData.tradeEnabled;
    }

    function maxGasPriceWei() external view returns (uint128) {
        return configData.maxGasPriceWei;
    }

    /// @dev return available balance of a token that reserve can use
    ///      if using weth, call getBalance(eth) will return weth balance
    ///      if using wallet for token, will return min of balance and allowance
    /// @param token token to get available balance that reserve can use
    function getBalance(IERC20Ext token) public view returns (uint256) {
        address wallet = getTokenWallet(token);
        IERC20Ext usingToken;

        if (token == ETH_TOKEN_ADDRESS) {
            if (wallet == address(this)) {
                // reserve should be using eth instead of weth
                return address(this).balance;
            }
            // reserve is using weth instead of eth
            usingToken = weth;
        } else {
            if (wallet == address(this)) {
                // not set token wallet or reserve is the token wallet, no need to check allowance
                return token.balanceOf(address(this));
            }
            usingToken = token;
        }

        uint256 balanceOfWallet = usingToken.balanceOf(wallet);
        uint256 allowanceOfWallet = usingToken.allowance(wallet, address(this));

        return minOf(balanceOfWallet, allowanceOfWallet);
    }

    /// @dev return wallet that holds the token
    ///      if token is ETH, check tokenWallet of WETH instead
    ///      if wallet is 0x0, consider as this reserve address
    function getTokenWallet(IERC20Ext token)
        public
        view
        returns (address wallet)
    {
        wallet = (token == ETH_TOKEN_ADDRESS)
            ? tokenWallet[address(weth)]
            : tokenWallet[address(token)];
        if (wallet == address(0)) {
            wallet = address(this);
        }
    }

    /// @dev do a trade, re-validate the conversion rate, remove trust assumption with network
    /// @param srcToken Src token
    /// @param srcAmount Amount of src token
    /// @param destToken Destination token
    /// @param destAddress Destination address to send tokens to
    function doTrade(
        IERC20Ext srcToken,
        uint256 srcAmount,
        IERC20Ext destToken,
        address payable destAddress,
        uint256 minRate
    ) internal {
        require(minRate > 0, "rate is 0");

        if (srcToken == ETH_TOKEN_ADDRESS) {
            require(msg.value == srcAmount, "wrong msg value");
        } else {
            require(msg.value == 0, "bad msg value");
        }
        require((srcToken == quoteToken) || (destToken == quoteToken), "one token must be quote");

        bool isBuy = srcToken == quoteToken;

        uint256 rate =
            conversionRatesContract.getRate(
                isBuy ? destToken : srcToken,
                block.number,
                isBuy,
                srcAmount
            );
        // re-validate conversion rate
        require(
            rate >= minRate,
            "reserve rate lower than requested rate"
        );
        if (sanityRatesContract != IKyberSanity(0)) {
            // sanity rate check
            uint256 sanityRate =
                sanityRatesContract.getSanityRate(srcToken, destToken);
            require(
                rate <= sanityRate,
                "rate should not be greater than sanity rate"
            );
        }

        uint256 destAmount =
            calcDestAmount(srcToken, destToken, srcAmount, rate);
        require(destAmount > 0, "dest amount is 0");
        
        _recieveToken(srcToken, msg.sender, srcAmount);
        _transferToken(destToken, destAddress, destAmount);

        if (isBuy) {
            // add to imbalance
            conversionRatesContract.recordImbalance(
                destToken,
                int256(destAmount),
                0,
                block.number
            );
        } else {
            // add to imbalance
            conversionRatesContract.recordImbalance(
                srcToken,
                -1 * int256(srcAmount),
                0,
                block.number
            );
        }

        emit TradeExecute(
            tx.origin,
            msg.sender,
            srcToken,
            srcAmount,
            destToken,
            destAmount,
            destAddress
        );
    }

    function _recieveToken(IERC20Ext token, address from, uint256 amount) internal {
        address walletToken = getTokenWallet(token);
        if (token == ETH_TOKEN_ADDRESS) {
            // only need to transfer weth if wallet token is different
            // eth should in this contract already
            if (walletToken != address(this)) {
                weth.deposit{value: amount}();
                IERC20Ext(weth).safeTransfer(
                    walletToken,
                    amount
                );
            }
        } else {
            token.safeTransferFrom(from, walletToken, amount);
        }
    }

    function _transferToken(IERC20Ext token, address to, uint256 amount) internal {
        address walletToken = getTokenWallet(token);
        if (token == ETH_TOKEN_ADDRESS) {
            if (walletToken == address(this)) {
                (bool success, ) = to.call { value: amount }("");
                require(success, "transfer eth failed");
            } else {
                IERC20Ext(weth).safeTransferFrom(walletToken, address(this), amount);
                weth.withdraw(amount);
                (bool success, ) = to.call { value: amount }("");
                require(success, "transfer eth failed");
            }
        } else {
            if (walletToken == address(this)) {
                token.safeTransfer(to, amount);
            } else {
                token.safeTransferFrom(walletToken, to, amount);
            }
        }
    }

}

