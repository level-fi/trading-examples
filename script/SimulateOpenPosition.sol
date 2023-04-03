// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

enum UpdatePositionType {
    INCREASE,
    DECREASE
}

enum OrderType {
    MARKET,
    LIMIT
}

enum Side {
    LONG,
    SHORT
}

interface ILevelOrderManager {
    function placeOrder(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) external payable;

    function nextOrderId() external view returns (uint256);
}

interface ILevelOracle {
    function postPrices(address[] calldata tokens, uint256[] calldata prices) external;
}

interface ITradeExecutor {
    function executeOrders(uint256[] calldata perpOrders, uint256[] calldata swapOrders) external;
}

interface IChainlinkPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

struct Position {
    uint256 size;
    uint256 collateralValue;
    uint256 reserveAmount;
    uint256 entryPrice;
    uint256 borrowIndex;
}

interface ILevelPool {
    function positions(bytes32) external view returns (Position memory);
}

contract SimulateOpenPosition is Script {
    uint256 public number;
    // only this address is allowed to post price to LevelOracle
    address PRICE_REPORTER = 0xe423BB0a8b925EABF625A8f36B468ab009a854e7;

    ILevelOracle LEVEL_ORACLE = ILevelOracle(0x04Db83667F5d59FF61fA6BbBD894824B233b3693);

    ILevelOrderManager LEVEL_ORDER_MANAGER = ILevelOrderManager(payable(0xf584A17dF21Afd9de84F47842ECEAF6042b1Bb5b));

    ILevelPool LEVEL_POOL = ILevelPool(0xA5aBFB56a78D2BD4689b25B8A77fd49Bb0675874);

    ITradeExecutor TRADE_EXECUTOR = ITradeExecutor(0x6cd4c40016F10E1609f16fB4a84CAe4700a4DaD6);

    address wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address chainlink_bnb = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    function run() external {
        address randomUser = address(new Address());

        // accquire some BNB
        vm.deal(randomUser, 1 ether);

        uint256 executionFee = 0.01 ether;
        uint256 bnbPrice = getChainlinkPrice();

        // PLACE ORDER
        uint256 price = (bnbPrice * 1e12) / 1e8; // since chainlink return price in decimals 8 but our protocol require 12
        address payToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // pseudo token to use inplace of chain native token
        uint256 payAmount = 0.1 ether;
        uint256 size = payAmount * 10 * price; // assume we want to long 10x
        uint256 collateralAmount = 0; // sent empty then contract will calculate from payAmount
        bytes memory data = abi.encode(price, payToken, payAmount, size, collateralAmount, bytes(""));
        console.log("PLACE ORDER: LONG BNB");
        console.log("size", size);
        console.log("payAmount", payAmount);
        console.log("price", price);

        vm.prank(randomUser);
        LEVEL_ORDER_MANAGER.placeOrder{value: executionFee + payAmount}(
            UpdatePositionType.INCREASE,
            Side.LONG,
            wbnb, // index token
            wbnb, // collateral token
            OrderType.MARKET,
            data
        );
        uint256 orderId = LEVEL_ORDER_MANAGER.nextOrderId() - 1;

        // KEEPER POST PRICE, this action suppose to executed by LevelKeeper
        // Please note that order may not be executed if the price is too far from chainlink price,
        // we sent the price accquired from chainlink before to prevent it happen
        vm.roll(block.number + 1);
        {
            address[] memory tokens = new address[](1);
            tokens[0] = wbnb;
            uint256[] memory prices = new uint[](1);
            prices[0] = bnbPrice;
            vm.startPrank(PRICE_REPORTER);
            LEVEL_ORACLE.postPrices(tokens, prices);
        }

        // EXECUTE ORDER, can be called by LevelKeeper, or anyone interest
        {
            uint256[] memory orders = new uint[](1);
            orders[0] = orderId;
            uint256[] memory swapOrders = new uint[](0);
            TRADE_EXECUTOR.executeOrders(orders, swapOrders);
        }
        // check if position is opened
        bytes32 positionId = keccak256(abi.encode(randomUser, wbnb, wbnb, Side.LONG));
        Position memory position = LEVEL_POOL.positions(positionId);
        assert(position.size == size);
    }

    function getChainlinkPrice() internal view returns (uint256) {
        (, int256 answer,,,) = IChainlinkPriceFeed(chainlink_bnb).latestRoundData();
        return uint256(answer);
    }
}

// empty contract to generate random address
contract Address {}
