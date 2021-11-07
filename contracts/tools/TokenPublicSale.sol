// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract TokenPublicSale is Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /**
     * EVENTS
     **/
    event TokenPurchased(address indexed user, address coin, uint coinAmount, uint256 tokenAmount);
    event TokensClaimed(address indexed user, uint256 tokenAmount);

    /**
     * CONSTANTS
     **/

    // *** support coin ***
    address public USDC;

    // *** SALE PARAMETERS ***
    uint256 public constant PRECISION = 1000000; //Up to 0.000001
    uint256 public constant WITHDRAWAL_PERIOD = 180 * 24 * 60 * 60; //0.5 year to withdrawal

    /***
     * STORAGE
     ***/

    uint256 public minTokensAmount; // minimum amount of TOKEN to buy per tx,like 1000 * 1e18
    uint256 public maxTokensAmount; // max amount of each address can buy
    uint256 public maxGasPrice; // mitigate front running

    // *** SALE PARAMETERS START ***

    AggregatorV3Interface public priceFeed;
    uint256 public  preSaleStart;
    uint256 public  preSaleEnd;
    uint256 public  preSaleTokenPool; // total amount of token in presale pool

    // *** SALE PARAMETERS END ***

    // *** VESTING PARAMETERS START ***

    uint256 public vestingStart; // seconds
    uint256 public vestingDuration; // seconds

    // *** VESTING PARAMETERS END ***

    address public token;
    uint256 public tokenPrice; // the price of token in usd multiply by PRECISION
    mapping(address => uint256) public purchased;
    mapping(address => uint256) internal _claimed;

    uint256 public purchasedPreSale;
    uint256 public basePrice; // the price of ETH in usd multiply by PRECISION

    address private treasury;
    address private keeper; // update base price

    /***
     * MODIFIERS
     ***/

    /**
    * @dev Throws if address is not owner or keeper.
    */
    modifier onlyKeeper() {
        require(_msgSender() == owner() || _msgSender() == keeper, "!Keeper");
        _;
    }

    /**
    * @dev Throws if called when no ongoing pre-sale or public sale.
    */
    modifier onlySale() {
        require(_isPreSale(), "Presale stages are over or not started");
        _;
    }

    /**
    * @dev Throws if sale stage is ongoing.
    */
    modifier notOnSale() {
        require(!_isPreSale(), "Presale is not over");
        _;
    }

    /**
    * @dev Throws if gas price exceeds gas limit.
    */
    modifier correctGas() {
        require(maxGasPrice == 0 || tx.gasprice <= maxGasPrice, "Gas price exceeds limit");
        _;
    }

    /***
     * INITIALIZER AND SETTINGS
     ***/

    constructor(address _treasury, address _keeper, address _usdc,
        address _token, uint256 _tokenPrice, uint256 _basePrice,
        uint256 _minTokensAmount, uint256 _maxTokensAmount, uint256 _preSaleTokenPool,
        uint256 _preSaleStart, uint256 _preSaleEnd, uint256 _vestingDuration) public {
        require(_treasury != address(0), "!treasury");
        require(_preSaleStart > 0, "!start");
        require(_preSaleEnd > _preSaleStart, "start >= end");
        require(_vestingDuration < WITHDRAWAL_PERIOD, "vestingDuration >= WITHDRAWAL_PERIOD");

        treasury = _treasury;
        keeper = _keeper;

        USDC = _usdc;
        token = _token;
        tokenPrice = _tokenPrice;
        basePrice = _basePrice;

        minTokensAmount = _minTokensAmount;
        maxTokensAmount = _maxTokensAmount;
        preSaleTokenPool = _preSaleTokenPool;

        preSaleStart = _preSaleStart;
        preSaleEnd = _preSaleEnd;
        vestingDuration = _vestingDuration;
    }

    /**
    * @notice Updates current priceFeed of chainlink.
    * @param _priceFeed New priceFeed
    */
    function adminSetPriceFeed(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /**
     * @notice Updates current vesting start time. Can be used once
     * @param _vestingStart New vesting start time
     */
    function adminSetVestingStart(uint256 _vestingStart) virtual external onlyOwner {
        require(vestingStart == 0, "Vesting start is already set");
        require(_vestingStart > preSaleEnd && block.timestamp < _vestingStart, "Incorrect time provided");
        vestingStart = _vestingStart;
    }

    /**
    * @notice Sets the rate based on the contracts precision
    * @param _price The price of ETH multiple by precision (e.g. _rate = PRECISION corresponds to $1)
    */
    function adminSetBasePrice(uint256 _price) external onlyKeeper {
        basePrice = _price;
    }

    /**
    * @notice Allows owner to change the treasury address. Treasury is the address where all funds from sale go to
    * @param _treasury New treasury address
    */
    function adminSetTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
    * @notice Allows owner to change min allowed token to buy per tx.
    * @param _minToken New min token amount
    */
    function adminSetMinToken(uint256 _minToken) external onlyOwner {
        minTokensAmount = _minToken;
    }

    /**
    * @notice Allows owner to change max allowed token per address.
    * @param _maxToken New max token amount
    */
    function adminSetMaxToken(uint256 _maxToken) external onlyOwner {
        maxTokensAmount = _maxToken;
    }

    /**
    * @notice Allows owner to change the max allowed gas price. Prevents gas wars
    * @param _maxGasPrice New max gas price
    */
    function adminSetMaxGasPrice(uint256 _maxGasPrice) external onlyOwner {
        maxGasPrice = _maxGasPrice;
    }

    /**
    * @notice Stops purchase functions. Owner only
    */
    function adminPause() external onlyOwner {
        _pause();
    }

    /**
    * @notice Unpauses purchase functions. Owner only
    */
    function adminUnpause() external onlyOwner {
        _unpause();
    }

    function adminAddPurchase(address _receiver, uint256 _amount) virtual external onlyOwner {
        purchased[_receiver] = purchased[_receiver].add(_amount);
    }

    /***
     * PURCHASE FUNCTIONS
     ***/

    /**
    * @notice For purchase with ETH
    */
    receive() external virtual payable onlySale whenNotPaused {
        _purchaseTokenWithETH();
    }

    /**
     * @notice For purchase with ETH. ETH is left on the contract until withdrawn to treasury
     */
    function purchaseTokenWithETH() external payable onlySale whenNotPaused {
        require(msg.value > 0, "No ETH sent");
        _purchaseTokenWithETH();
    }

    function _purchaseTokenWithETH() private correctGas {
        uint256 purchasedAmount = calcEthPurchasedAmount(msg.value);
        require(purchasedAmount >= minTokensAmount, "Minimum required unreached");

        require(purchasedPreSale.add(purchasedAmount) <= preSaleTokenPool, "Not enough token in presale pool");
        purchasedPreSale = purchasedPreSale.add(purchasedAmount);
        purchased[_msgSender()] = purchased[_msgSender()].add(purchasedAmount);
        require(purchased[_msgSender()] <= maxTokensAmount, "Maximum allowed exceeded");

        emit TokenPurchased(_msgSender(), address(0), msg.value, purchasedAmount);
    }

    /**
    * @notice For purchase with allowed stablecoin (USDC)
    * @param coin Address of the token to be paid in
    * @param amount Amount of the token to be paid in
    */
    function purchaseTokenWithCoin(address coin, uint256 amount) external onlySale whenNotPaused correctGas {
        require(coin == USDC, "Coin is not supported!");
        uint256 purchasedAmount = calcCoinPurchasedAmount(coin, amount);
        require(purchasedAmount >= minTokensAmount, "Minimum required unreached");

        purchasedPreSale = purchasedPreSale.add(purchasedAmount);
        require(purchasedPreSale <= preSaleTokenPool, "Token is not enough!");
        purchased[_msgSender()] = purchased[_msgSender()].add(purchasedAmount);
        require(purchased[_msgSender()] <= maxTokensAmount, "Maximum allowed exceeded");

        IERC20(coin).safeTransferFrom(_msgSender(), address(this), amount);

        emit TokenPurchased(_msgSender(), coin, amount, purchasedAmount);
    }


    /**
     * @notice Function for the administrator to withdraw token
     * @notice Withdrawals allowed only if there is no sale pending stage
     * @param ERC20token Address of ERC20 token to withdraw from the contract
     */
    function adminWithdrawERC20(address ERC20token) external onlyOwner notOnSale {
        uint256 withdrawAmount;
        if (ERC20token != token) {
            withdrawAmount = IERC20(ERC20token).balanceOf(address(this));
        } else {
            if (block.timestamp >= vestingStart.add(WITHDRAWAL_PERIOD)) {
                withdrawAmount = IERC20(ERC20token).balanceOf(address(this));
            } else {
                withdrawAmount = IERC20(ERC20token).balanceOf(address(this)).sub(purchasedPreSale);
            }
        }

        require(withdrawAmount > 0, "No ERC20 to withdraw");
        IERC20(ERC20token).safeTransfer(treasury, withdrawAmount);
    }

    /**
     * @notice Function for the administrator to withdraw ETH for refunds
     * @notice Withdrawals allowed only if there is no sale pending stage
     */
    function adminWithdrawETH() external onlyOwner notOnSale {
        require(address(this).balance > 0, "No ETH to withdraw");

        (bool success,) = treasury.call{value : address(this).balance}("");
        require(success, "Transfer failed");
    }

    /***
     * VESTING INTERFACE
     ***/

    /**
     * @notice Transfers available for claim vested tokens to the user.
     */
    function claim() external notOnSale {
        require(vestingStart != 0, "Vesting start is not set");
        uint256 unclaimed = claimable(_msgSender());
        require(unclaimed > 0, "TokenVesting: no tokens are due");

        _claimed[_msgSender()] = _claimed[_msgSender()].add(unclaimed);
        IERC20(token).safeTransfer(_msgSender(), unclaimed);
        emit TokensClaimed(_msgSender(), unclaimed);
    }

    /**
     * @notice Gets the amount of tokens the user has already claimed
     * @param _user Address of the user who purchased tokens
     * @return The amount of the token claimed.
     */
    function claimed(address _user) external view returns (uint256) {
        return _claimed[_user];
    }

    /**
     * @notice Calculates the amount that has already vested but hasn't been claimed yet.
     * @param _user Address of the user who purchased tokens
     * @return The amount of the token vested and unclaimed.
     */
    function claimable(address _user) public view returns (uint256) {
        return _vestedAmount(_user).sub(_claimed[_user]);
    }

    /**
    * @notice Calculates the amount that is still locked.
    * @param _user Address of the user who purchased tokens
    * @return The amount of the token vested and unclaimed.
    */
    function locked(address _user) public view returns (uint256) {
        return purchased[_user].sub(_vestedAmount(_user));
    }

    /**
     * @dev Calculates the amount that has already vested.
     * @param _user Address of the user who purchased tokens
     * @return Amount of token already vested
     */
    function _vestedAmount(address _user) private view returns (uint256) {
        if (vestingStart == 0 || block.timestamp < vestingStart) {
            return 0;
        } else if (block.timestamp >= vestingStart.add(vestingDuration)) {
            return purchased[_user];
        } else {
            return purchased[_user].mul(block.timestamp.sub(vestingStart)).div(vestingDuration);
        }
    }


    /**
     * @dev Calculates Token amount based on rate and ETH amount.
     * @param _amount ETH amount to convert to token
     * @return Token amount
     */
    function calcEthPurchasedAmount(uint256 _amount) public view returns (uint256) {
        if (address(priceFeed) != address(0)) {
            uint decimals = priceFeed.decimals();
            (,int256 price,,,) = priceFeed.latestRoundData();
            return _amount.mul(uint256(price)).mul(PRECISION).div(tokenPrice).div(10 ** decimals);
        } else {
            return _amount.mul(basePrice).div(tokenPrice);
        }
    }

    /**
     * @dev Calculates token amount based on amount of token.
     * @param _coin Supported ERC20 token
     * @param _amount Coin amount to convert to token
     * @return purchasedAmount Token amount to buy
     */
    function calcCoinPurchasedAmount(address _coin, uint256 _amount) public view returns (uint256) {
        uint256 amountInUsd = _amount.mul(1e18).div(10 ** (uint256(ERC20(_coin).decimals())));
        return amountInUsd.mul(PRECISION).div(tokenPrice);
    }

    /***
     * INTERNAL HELPERS
     ***/


    /**
     * @dev Checks if presale stage is on-going.
     * @return True is presale is active
     */
    function _isPreSale() virtual internal view returns (bool) {
        return (block.timestamp >= preSaleStart && block.timestamp < preSaleEnd);
    }
}